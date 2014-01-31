# cookie.rb is redistributed file which is originally included in Webagent
# version 0.6.2 by TAKAHASHI `Maki' Masayoshi.  And it contains some bug fixes.
# You can download the entire package of Webagent from
# http://www.rubycolor.org/arc/.


# Cookie class
#
# I refered to w3m's source to make these classes. Some comments
# are quoted from it. I'm thanksful for author(s) of it.
#
#    w3m homepage:  http://ei5nazha.yz.yamagata-u.ac.jp/~aito/w3m/eng/

require 'time'
require 'monitor'
require 'httpclient/util'

class WebAgent

  module CookieUtils

    def head_match?(str1, str2)
      str2.start_with? str1
    end

    def domain_match(host, domain)
      return false if host.nil? or domain.nil?
      @domain_match_cache ||= {}
      key = (host + "|" + domain).downcase
      if !@domain_match_cache.key?(key)
        domainname = domain.sub(/\.\z/, '').downcase
        hostname = host.sub(/\.\z/, '').downcase
        @domain_match_cache[key] = case domain
        when '.'
          true
        when /^\./
          ("." + hostname).end_with?(domainname)
        else
          hostname == domainname
        end
      end
      @domain_match_cache[key]
    end
  end

  class Cookie
    include CookieUtils

    attr_accessor :name, :value
    attr_accessor :domain, :path
    attr_accessor :expires      ## for Netscape Cookie
    attr_accessor :url
    attr_writer :use, :secure, :http_only, :discard, :domain_orig, :path_orig, :override

    USE = 1
    SECURE = 2
    DOMAIN = 4
    PATH = 8
    DISCARD = 16
    OVERRIDE = 32
    OVERRIDE_OK = 32
    HTTP_ONLY = 64

    def initialize
      @name = @value = @domain = @path = nil
      @expires = nil
      @url = nil
      @use = @secure = @http_only = @discard = @domain_orig = @path_orig = @override = nil
    end

    def discard?
      @discard
    end

    def use?
      @use
    end

    def secure?
      @secure
    end

    def http_only?
      @http_only
    end

    def domain_orig?
      @domain_orig
    end

    def path_orig?
      @path_orig
    end

    def override?
      @override
    end

    def flag
      flg = 0
      flg += USE        if @use
      flg += SECURE     if @secure
      flg += HTTP_ONLY  if @http_only
      flg += DOMAIN     if @domain_orig
      flg += PATH       if @path_orig
      flg += DISCARD    if @discard
      flg += OVERRIDE   if @override
      flg
    end

    def set_flag(flag)
      flag = flag.to_i
      @use         = true if flag & USE > 0
      @secure      = true if flag & SECURE > 0
      @http_only   = true if flag & HTTP_ONLY > 0
      @domain_orig = true if flag & DOMAIN > 0
      @path_orig   = true if flag & PATH > 0
      @discard     = true if flag & DISCARD > 0
      @override    = true if flag & OVERRIDE > 0
    end

    def match?(url)
      domainname = url.host
      domainname &&
        domain_match(domainname, @domain) &&
        (!@path || (url.path.empty? ? '/' : url.path).start_with?(@path)) &&
        (!@secure || url.scheme == 'https')
    end

    def join_quotedstr(array, sep)
      ret = Array.new
      old_elem = nil
      array.each{|elem|
        if (elem.scan(/"/).length % 2) == 0
          if old_elem
            old_elem << sep << elem
          else
            ret << elem
            old_elem = nil
          end
        else
          if old_elem
            old_elem << sep << elem
            ret << old_elem
            old_elem = nil
          else
            old_elem = elem.dup
          end
        end
      }
      ret
    end

    def parse(str, url)
      @url = url
      # TODO: should not depend on join_quotedstr. scan with escape like CSV.
      cookie_elem = str.split(/;/)
      cookie_elem = join_quotedstr(cookie_elem, ';')
      cookie_elem -= [""] # del empty elements, a cookie might included ";;"
      first_elem = cookie_elem.shift
      if first_elem !~ /([^=]*)(\=(.*))?/
        return
        ## raise ArgumentError 'invalid cookie value'
      end
      @name = $1.strip
      @value = normalize_cookie_value($3)
      cookie_elem.each do |pair|
        key, value = pair.split(/\=/, 2)  ## value may nil
        key.strip!
        value = normalize_cookie_value(value)
        case key.downcase
        when 'domain'
          @domain = value
        when 'expires'
          @expires = nil
          begin
            @expires = Time.parse(value).gmtime if value
          rescue ArgumentError
          end
        when 'path'
          @path = value
        when 'secure'
          @secure = true  ## value may nil, but must 'true'.
        when 'httponly'
          @http_only = true  ## value may nil, but must 'true'.
        else
          ## ignore
        end
      end
    end

  private

    def normalize_cookie_value(value)
      if value
        value = value.strip.sub(/\A"(.*)"\z/) { $1 }
        value = nil if value.empty?
      end
      value
    end
  end

  class CookieManager
    include CookieUtils

    ### errors
    class Error < StandardError; end
    class ErrorOverrideOK < Error; end
    class SpecialError < Error; end

    attr_reader :cookies
    attr_accessor :cookies_file
    attr_accessor :accept_domains, :reject_domains

    def initialize(file=nil)
      @cookies = Array.new
      @cookies.extend(MonitorMixin)
      @cookies_file = file
      @is_saved = true
      @reject_domains = Array.new
      @accept_domains = Array.new
      @netscape_rule = false
    end

    def cookies=(cookies)
      @cookies = cookies
      @cookies.extend(MonitorMixin)
    end

    def save_all_cookies(force = nil, save_unused = true, save_discarded = true)
      @cookies.synchronize do
        check_expired_cookies
        if @is_saved and !force
          return
        end
        File.open(@cookies_file, 'w') do |f|
          @cookies.each do |cookie|
            if (cookie.use? or save_unused) and
                (!cookie.discard? or save_discarded)
              f.print(cookie.url.to_s,"\t",
                      cookie.name,"\t",
                      cookie.value,"\t",
                      cookie.expires.to_i,"\t",
                      cookie.domain,"\t",
                      cookie.path,"\t",
                      cookie.flag,"\n")
            end
          end
        end
      end
      @is_saved = true
    end

    def save_cookies(force = nil)
      save_all_cookies(force, false, false)
    end

    def check_expired_cookies
      now = Time.now.gmtime
      @cookies.reject! do |cookie|
        is_expired = (cookie.expires && cookie.expires < now)
        if is_expired && !cookie.discard?
          @is_saved = false
        end
        is_expired
      end
    end

    def parse(str, url)
      cookie = WebAgent::Cookie.new
      cookie.parse(str, url)
      add(cookie)
    end

    def find(url)
      return nil if @cookies.empty?

      now = Time.now.gmtime
      cookies = []
      cookie_names = {}
      @cookies.each do |cookie|
        select = false
        if cookie.use? && (!cookie.expires || cookie.expires > now) && cookie.match?(url)
          if !cookie_names.key?(cookie.name)
            cookies << cookie
            cookie_names[cookie.name] = true
          end
        end
      end
      make_cookie_str cookies
    end

    def add(given)
      check_domain(given.domain, given.url.host, given.override?)

      domain = given.domain || given.url.host
      path = given.path || given.url.path.sub(%r|/[^/]*\z|, '')

      cookie = nil
      @cookies.synchronize do
        check_expired_cookies
        cookie = @cookies.find { |c|
          c.domain == domain && c.path == path && c.name == given.name
        }
        if !cookie
          cookie = WebAgent::Cookie.new
          cookie.use = true
          @cookies << cookie
        end
      end

      cookie.domain = domain
      cookie.path = path
      cookie.url = given.url
      cookie.name = given.name
      cookie.value = given.value
      cookie.expires = given.expires
      cookie.secure = given.secure?
      cookie.http_only = given.http_only?
      cookie.domain_orig = given.domain
      cookie.path_orig = given.path

      if cookie.discard? || cookie.expires == nil
        cookie.discard = true
      else
        cookie.discard = false
        @is_saved = false
      end
    end

    def load_cookies
      return if !File.readable?(@cookies_file)
      @cookies.synchronize do
        @cookies.clear
        File.open(@cookies_file,'r'){|f|
          while line = f.gets
            cookie = WebAgent::Cookie.new
            @cookies << cookie
            col = line.chomp.split(/\t/)
            cookie.url = HTTPClient::Util.urify(col[0])
            cookie.name = col[1]
            cookie.value = col[2]
            if col[3].empty? or col[3] == '0'
              cookie.expires = nil
            else
              cookie.expires = Time.at(col[3].to_i).gmtime
            end
            cookie.domain = col[4]
            cookie.path = col[5]
            cookie.set_flag(col[6])
          end
        }
      end
    end

    # Who use it?
    def check_cookie_accept_domain(domain)
      unless domain
        return false
      end
      @accept_domains.each{|dom|
        if domain_match(domain, dom)
          return true
        end
      }
      @reject_domains.each{|dom|
        if domain_match(domain, dom)
          return false
        end
      }
      return true
    end

  private

    def make_cookie_str(cookie_list)
      if cookie_list.empty?
        return nil
      end

      ret = ''
      c = cookie_list.shift
      ret += "#{c.name}=#{c.value}"
      cookie_list.each{|cookie|
        ret += "; #{cookie.name}=#{cookie.value}"
      }
      return ret
    end

    # for conformance to http://wp.netscape.com/newsref/std/cookie_spec.html
    attr_accessor :netscape_rule
    SPECIAL_DOMAIN = [".com",".edu",".gov",".mil",".net",".org",".int"]

    def check_domain(domain, hostname, override)
      return unless domain

      # [DRAFT 12] s. 4.2.2 (does not apply in the case that
      # host name is the same as domain attribute for version 0
      # cookie)
      # I think that this rule has almost the same effect as the
      # tail match of [NETSCAPE].
      if domain !~ /^\./ && hostname != domain
        domain = '.'+domain
      end
      # [NETSCAPE] rule
      if @netscape_rule
        n = domain.scan(/\./).length
        if n < 2
          cookie_error(SpecialError.new, override)
        elsif n == 2
          ## [NETSCAPE] rule
          ok = SPECIAL_DOMAIN.select{|sdomain|
            sdomain == domain[-(sdomain.length)..-1]
          }
          if ok.empty?
            cookie_error(SpecialError.new, override)
          end
        end
      end
      # this implementation does not check RFC2109 4.3.2 case 2;
      # the portion of host not in domain does not contain a dot.
      # according to nsCookieService.cpp in Firefox 3.0.4, Firefox 3.0.4
      # and IE does not check, too.
    end

    # not tested well; used only netscape_rule = true.
    def cookie_error(err, override)
      if !err.kind_of?(ErrorOverrideOK) || !override
        raise err
      end
    end
  end
end
