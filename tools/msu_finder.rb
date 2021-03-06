#!/usr/bin/env ruby

###
#
# This sceript will enumerate download links for Microsoft patches.
#
# Author:
# * sinn3r
#
###


msfbase = __FILE__
while File.symlink?(msfbase)
  msfbase = File.expand_path(File.readlink(msfbase), File.dirname(msfbase))
end
$:.unshift(File.expand_path(File.join(File.dirname(msfbase), '..', 'lib')))
require 'rex'
require 'nokogiri'
require 'uri'
require 'json'
require 'optparse'

module MicrosoftPatchFinder

  module SiteInfo
    TECHNET = {
      ip:    '157.56.148.23',
      vhost: 'technet.microsoft.com'
    }

    MICROSOFT = {
      ip:    '104.72.230.162',
      vhost: 'www.microsoft.com'
    }

    GOOGLEAPIS = {
      ip:    '74.125.28.95',
      vhost: 'www.googleapis.com'
    }
  end

  # This provides whatever other classes need.
  module Helper

    # Prints a debug message.
    #
    # @param msg [String] The message to print.
    # @return [void]
    def print_debug(msg='')
      $stderr.puts "[DEBUG] #{msg}"
    end

    # Prints a status message.
    #
    # @param msg [String] The message to print.
    # @return [void]
    def print_status(msg='')
      $stderr.puts "[*] #{msg}"
    end

    # Prints an error message.
    #
    # @param msg [String] The message to print.
    # @return [void]
    def print_error(msg='')
      $stderr.puts "[ERROR] #{msg}"
    end

    # Prints a regular message.
    #
    # @param msg [String] The message to print.
    # @return pvoid
    def print_line(msg='')
      $stdout.puts msg
    end

    # Sends an HTTP request with Rex.
    #
    # @param rhost [Hash] Information about the target host. Use MicrosoftPatchFinder::SiteInfo.
    # @option rhost [String] :vhost
    # @option rhost [String] :ip IPv4 address
    # @param opts [Hash] Information about the Rex request.
    # @raise [RuntimeError] Failure to make a request.
    # @return [Rex::Proto::Http::Response]
    def send_http_request(rhost, opts={})
      res = nil

      opts.merge!({'vhost'=>rhost[:vhost]})

      print_debug("Requesting: #{opts['uri']}")

      cli = Rex::Proto::Http::Client.new(rhost[:ip], 443, {}, true, 'TLS1')
      tries = 1
      begin
        cli.connect
        req = cli.request_cgi(opts)
        res = cli.send_recv(req)
      rescue ::EOFError, Errno::ETIMEDOUT ,Errno::ECONNRESET, Rex::ConnectionError, OpenSSL::SSL::SSLError, ::Timeout::Error => e
        if tries < 3
          print_error("Failed to make a request, but will try again in 5 seconds...")
          sleep(5)
          tries += 1
          retry
        else
          raise "[x] Unable to make a request: #{e.class} #{e.message}\n#{e.backtrace * "\n"}"
        end
      ensure
        cli.close
      end

      res
    end
  end


  # Collects MSU download links from Technet.
  class PatchLinkCollector
    include MicrosoftPatchFinder::Helper

    # Returns a response of an advisory page.
    #
    # @param msb [String] MSB number in this format: msxx-xxx
    # @return [Rex::Proto::Http::Response]
    def download_advisory(msb)
      send_http_request(SiteInfo::TECHNET, {
        'uri' => "/en-us/library/security/#{msb}.aspx"
      })
    end


    # Returns the most appropriate pattern that could be used to parse and extract links from an advisory.
    #
    # @param n [Nokogiri::HTML::Document] The advisory page parsed by Nokogiri
    # @return [Hash]
    def get_appropriate_pattern(n)
      # These pattern checks need to be in this order.
      patterns = [
        # This works from MS14-001 until the most recent
        {
          check:   '//div[@id="mainBody"]//div//h2//div//span[contains(text(), "Affected Software")]',
          pattern: '//div[@id="mainBody"]//div//div[@class="sectionblock"]//table//a' 
        },
        # This works from ms03-040 until MS07-029
        {
          check:   '//div[@id="mainBody"]//ul//li//a[contains(text(), "Download the update")]',
          pattern: '//div[@id="mainBody"]//ul//li//a[contains(text(), "Download the update")]'
        },
        # This works from sometime until ms03-039
        {
          check:   '//div[@id="mainBody"]//div//div[@class="sectionblock"]//p//strong[contains(text(), "Download locations")]',
          pattern: '//div[@id="mainBody"]//div//div[@class="sectionblock"]//ul//li//a'
        },
        # This works from MS07-030 until MS13-106 (the last update in 2013)
        # The check is pretty short so if it kicks in too early, it tends to create false positives.
        # So it goes last.
        {
          check:   '//div[@id="mainBody"]//p//strong[contains(text(), "Affected Software")]',
          pattern: '//div[@id="mainBody"]//table//a' 
        },
      ]

      patterns.each do |pattern|
        if n.at_xpath(pattern[:check])
          return pattern[:pattern]
        end
      end

      nil
    end


    # Returns the details page for an advisory.
    #
    # @param res [Rex::Proto::Http::Response]
    # @return [Array<URI::HTTP>] An array of URI objects.
    def get_details_aspx(res)
      links = []

      page = res.body
      n = ::Nokogiri::HTML(page)

      appropriate_pattern = get_appropriate_pattern(n)

      n.search(appropriate_pattern).each do |anchor|
        found_link = anchor.attributes['href'].value
        if /https:\/\/www\.microsoft\.com\/downloads\/details\.aspx\?familyid=/i === found_link
          begin
            links << URI(found_link)
          rescue ::URI::InvalidURIError
            print_error "Unable to parse URI: #{found_link}"
          end
        end
      end

      links
    end


    # Returns the redirected page.
    #
    # @param rhost [Hash] From MicrosoftPatchFinder::SiteInfo
    # @param res [Rex::Proto::Http::Response]
    # @return [Rex::Proto::Http::Response]
    def follow_redirect(rhost, res)
      opts = {
        'method' => 'GET',
        'uri'    => res.headers['Location']
      }

      send_http_request(rhost, opts)
    end


    # Returns the download page of an advisory.
    #
    # @param uri [URI::HTTP]
    # @return [Rex::Proto::Http::Response]
    def get_download_page(uri)
      opts = {
        'method' => 'GET',
        'uri'    => uri.request_uri
      }

      res = send_http_request(SiteInfo::MICROSOFT, opts)

      if res.headers['Location']
        return follow_redirect(SiteInfo::MICROSOFT, res)
      end

      res
    end


    # Returns a collection of found MSU download links from an advisory.
    #
    # @param page [String] The HTML page of the advisory.
    # @return [Array<String>] An array of links
    def get_download_links(page)
      page = ::Nokogiri::HTML(page)

      relative_uri = page.search('a').select { |a|
        a.attributes['href'] && a.attributes['href'].value.include?('confirmation.aspx?id=')
      }.first

      return [] unless relative_uri
      relative_uri = relative_uri.attributes['href'].value

      absolute_uri = URI("https://www.microsoft.com/en-us/download/#{relative_uri}")
      opts = {
        'method' => 'GET',
        'uri' => absolute_uri.request_uri
      }
      res = send_http_request(SiteInfo::MICROSOFT, opts)
      n = ::Nokogiri::HTML(res.body)

      n.search('a').select { |a|
        a.attributes['href'] && a.attributes['href'].value.include?('http://download.microsoft.com/download/')
      }.map! { |a| a.attributes['href'].value }.uniq
    end


    # Returns whether the page is an advisory or not.
    #
    # @param res [Rex::Proto::Http::Response]
    # @return [Boolean] true if the page is an advisory, otherwise false.
    def has_advisory?(res)
      !res.body.include?('We are sorry. The page you requested cannot be found')
    end


    # Returns whether the number is in valid MSB format or not.
    #
    # @param msb [String] The number to check.
    # @return [Boolean] true if the number is in MSB format, otherwise false.
    def is_valid_msb?(msb)
      /^ms\d\d\-\d\d\d$/i === msb
    end
  end


  # A class that searches advisories from Technet.
  class TechnetMsbSearch
    include MicrosoftPatchFinder::Helper

    def initialize
      opts = {
        'method' => 'GET',
        'uri'    => '/en-us/security/bulletin/dn602597.aspx'
      }
      res = send_http_request(SiteInfo::TECHNET, opts)
      @firstpage ||= res.body
    end


    # Returns a collection of found MSB numbers either from the product list, or generic search.
    #
    # @param keyword [String] The product to look for.
    # @return [Array<String>]
    def find_msb_numbers(keyword)
      product_list_matches = get_product_dropdown_list.select { |p| Regexp.new(keyword) === p[:option_text] }
      if product_list_matches.empty?
        print_debug("Did not find a match from the product list, attempting a generic search")
        search_by_keyword(keyword)
      else
        product_names = []
        ids = []
        product_list_matches.each do |e|
          ids << e[:option_value]
          product_names << e[:option_text]
        end
        print_debug("Matches from the product list (#{product_names.length}): #{ product_names * ', ' }")
        search_by_product_ids(ids)
      end
    end


    # Returns the search results in JSON format.
    #
    # @param keyword [String] The keyword to search.
    # @return [Hash] JSON data.
    def search(keyword)
      opts = {
        'method' => 'GET',
        'uri'    => '/security/bulletin/services/GetBulletins',
        'vars_get' => {
          'searchText'       => keyword,
          'sortField'        => '0',
          'sortOrder'        => '1',
          'currentPage'      => '1',
          'bulletinsPerPage' => '9999',
          'locale'           => 'en-us'
        }
      }
      res = send_http_request(SiteInfo::TECHNET, opts)
      begin
        return JSON.parse(res.body)
      rescue JSON::ParserError
      end

      {}
    end


    # Performs a search based on product IDs
    #
    # @param ids [Array<Fixnum>] An array of product IDs.
    # @return [Array<String>] An array of found MSB numbers.
    def search_by_product_ids(ids)
      msb_numbers = []

      ids.each do |id|
        j = search(id)
        msb = j['b'].collect { |e| e['Id']}.map{ |e| e.downcase}
        msb_numbers.concat(msb)
      end

      msb_numbers
    end


    # Performs a search based on a keyword
    #
    # @param keyword [String]
    # @return [Array<String>] An array of found MSB numbers
    def search_by_keyword(keyword)
      j = search(keyword)
      j['b'].collect { |e| e['Id']}.map{ |e| e.downcase }
    end


    # Returns the product list that Technet currently supports for searching.
    #
    # @return [Array<Hash>]
    def get_product_dropdown_list
      @product_dropdown_list ||= lambda {
        list = []

        page = ::Nokogiri::HTML(firstpage)
        page.search('//div[@class="sb-search"]//select[@id="productDropdown"]//option').each do |product|
          option_value = product.attributes['value'].value
          option_text  = product.text
          next if option_value == '-1' # This is the ALL option
          list << { option_value: option_value, option_text: option_text }
        end

        list
      }.call
    end

    attr_reader :firstpage
  end

  class GoogleMsbSearch
    include MicrosoftPatchFinder::Helper

    # API Doc:
    # https://developers.google.com/custom-search/json-api/v1/using_rest
    # Known bug:
    # * Always gets 20 MSB results. Weird.

    def initialize(opts={})
      @api_key = opts[:api_key]
      @search_engine_id = opts[:search_engine_id]
    end


    # Returns the MSB numbers associated with the keyword.
    #
    # @param keyword [String] The keyword to search for in an advisory.
    # @return [Array<String>] MSB numbers
    def find_msb_numbers(keyword)
      msb_numbers = []
      next_starting_index = 1

      begin
        while
          results = search(keyword: keyword, starting_index: next_starting_index)
          items = results['items']
          items.each do |item|
            title = item['title']
            msb = title.scan(/Microsoft Security Bulletin (MS\d\d\-\d\d\d)/).flatten.first
            if msb
              msb_numbers << msb.downcase
            end
          end

          next_starting_index = get_next_index(results)
          next_page = results['queries']['nextPage']

          # Google API Documentation:
          # https://developers.google.com/custom-search/json-api/v1/using_rest
          # "This role is not present if the current results are the last page.
          # Note: This API returns up to the first 100 results only."
          break if next_page.nil? || next_starting_index > 100
        end
      rescue RuntimeError => e
        print_error(e.message)
        return msb_numbers.uniq
      end

      msb_numbers.uniq
    end


    # Performs a search using Google API
    #
    # @param opts [Hash]
    # @options opts [String] :keyword The keyword to search
    # @return [Hash] JSON data
    def search(opts={})
      starting_index = opts[:starting_index]

      search_string = [
        opts[:keyword],
        'intitle:"Microsoft Security Bulletin"',
        '-"Microsoft Security Bulletin Summary"'
      ].join(' ')

      opts = {
        'method' => 'GET',
        'uri' => '/customsearch/v1',
        'vars_get' => {
          'key'    => api_key,
          'cx'     => search_engine_id,
          'q'      => search_string,
          'start'  => starting_index.to_s,
          'num'    => '10', # 10 is max
          'c2coff' => '1' # 1 = Disabled, 0 = Enabled
        }
      }

      res = send_http_request(SiteInfo::GOOGLEAPIS, opts)
      results = parse_results(res)
      if starting_index == 1
        print_debug("Number of search results: #{get_total_results(results)}")
      end

      results
    end


    # Parse Google API search results
    #
    # @param res [Rex::Proto::Http::Response]
    # @raise [RuntimeError] If Google returns an error
    # @return [Hash]
    def parse_results(res)
      j = JSON.parse(res.body)

      if j['error']
        message = j['error']['errors'].first['message']
        reason  = j['error']['errors'].first['reason']
        raise "Google Search failed. #{message} (#{reason})"
      end

      j
    end


    # Returns the total results.
    #
    # @param j [Hash] JSON data from Google.
    # @return [Fixnum]
    def get_total_results(j)
      j['queries']['request'].first['totalResults'].to_i
    end


    # Returns the next index.
    #
    # @param j [Hash] JSON data from Google.
    # @return [Fixnum]
    def get_next_index(j)
      j['queries']['nextPage'] ? j['queries']['nextPage'].first['startIndex'] : 0
    end

    # @!attribute api_key
    #  @return [String] The Google API key
    attr_reader :api_key

    # @!attribute search_engine_id
    #  @return [String] The Google Custom Search Engine ID
    attr_reader :search_engine_id
  end

  class OptsConsole
    def self.banner
    %Q|
    Usage: #{__FILE__} [options]

    The following example will download all IE update links:
    #{__FILE__} -q "Internet Explorer"

    Searching advisories via Technet:
    When you submit a query, the Technet search engine will first look it up from a product list,
    and then return all the advisories that include the keyword you are looking for. If there's
    no match from the product list, then the script will try a generic search. The generic method
    also means you can search by MSB, KB, or even the CVE number.

    Searching advisories via Google:
    Searching via Google requires an API key and an Search Engine ID from Google. To obtain these,
    make sure you have a Google account (such as Gmail), and then do the following:
    1. Go to Google Developer's Console
       1. Enable Custom Search API
       2. Create a browser type credential. The credential is the API key.
    2. Go to Custom Search
       1. Create a new search engine
       2. Under Sites to Search, set: technet.microsoft.com
       3. In your search site, get the Search Engine ID under the Basics tab.
    By default, Google has a quota limit of 1000 queries per day. You can raise this limit with
    a fee.

    The way this tool uses Google to find advisories is the same as doing the following manually:
    [Query] site:technet.microsoft.com intitle:"Microsoft Security Bulletin" -"Microsoft Security Bulletin Summary"

    Dryrun:
    If you'd like to double check on false positives, you can use the -d flag and manually verify
    the accuracy of the search results before actually collecting the download links.

    Download:
    The following trick demonstrates how you can automatically download the updates:
    ruby #{__FILE__} -q "ms15-100" -r x86 > /tmp/list.txt && wget -i /tmp/list.txt

    Patch Extraction:
    After downloading the patch, you can use the extract_msu.bat tool to automatically extract
    Microsoft patches.
    |
    end

    def self.get_parsed_options
      options = {}

      parser = OptionParser.new do |opt|
        opt.banner = banner.strip.gsub(/^[[:blank:]]{4}/, '')
        opt.separator ''
        opt.separator 'Specific options:'

        opt.on('-q', '--query <keyword>', 'Find advisories that include this keyword') do |v|
          options[:keyword] = v
        end

        opt.on('-s', '--search-engine <engine>', '(Optional) The type of search engine to use (Technet or Google). Default: Technet') do |v|
          case v.to_s
          when /^google$/i
            options[:search_engine] = :google
          when /^technet$/i
            options[:search_engine] = :technet
          else
            raise OptionParser::MissingArgument, "Invalid search engine: #{v}"
          end
        end

        opt.on('-r', '--regex <string>', '(Optional) Specify what type of links you want') do |v|
          options[:regex] = v
        end

        opt.on('--apikey <key>', '(Optional) Google API key. Set this if the search engine is Google') do |v|
          options[:google_api_key] = v
        end

        opt.on('--cx <id>', '(Optional) Google search engine ID. Set this if the search engine is Google') do |v|
          options[:google_search_engine_id] = v
        end

        opt.on('-d', '--dryrun', '(Optional) Perform a search, but do not fetch download links. Default: no') do |v|
          options[:dryrun] = true
        end

        opt.on_tail('-h', '--help', 'Show this message') do
          $stderr.puts opt
          exit
        end
      end

      parser.parse!

      if options.empty?
        raise OptionParser::MissingArgument, 'No options set, try -h for usage'
      elsif options[:keyword].nil? || options[:keyword].empty?
        raise OptionParser::MissingArgument, '-q is required'
      end

      unless options[:search_engine]
        options[:search_engine] = :technet
      end

      if options[:search_engine] == :google
        if options[:google_api_key].nil? || options[:google_search_engine_id].empty?
          raise OptionParser::MissingArgument, 'Search engine is Google, but no API key specified'
        elsif options[:google_search_engine_id].nil? || options[:google_search_engine_id].empty?
          raise OptionParser::MissingArgument, 'Search engine is Google, but no search engine ID specified'
        end
      end

      options
    end
  end

  class Driver
    include MicrosoftPatchFinder::Helper

    def initialize
      begin
        @args = MicrosoftPatchFinder::OptsConsole.get_parsed_options
      rescue OptionParser::InvalidOption, OptionParser::MissingArgument => e
        print_error(e.message)
        exit
      end
    end

    # Returns download links.
    #
    # @param msb [String] MSB number.
    # @param regex [String] The regex pattern to use to collect specific download URLs.
    # @return [Array<String>] Download links
    def get_download_links(msb, regex=nil)
      msft = MicrosoftPatchFinder::PatchLinkCollector.new

      unless msft.is_valid_msb?(msb)
        print_error "Not a valid MSB format."
        print_error "Example of a correct one: ms15-100"
        return []
      end

      res = msft.download_advisory(msb)

      if !msft.has_advisory?(res)
        print_error "The advisory cannot be found"
        return []
      end

      links = msft.get_details_aspx(res)
      if links.length == 0
        print_error "Unable to find download.microsoft.com links. Please manually navigate to the page."
        return []
      else
        print_debug("Found #{links.length} affected products for this advisory.")
      end

      link_collector = []

      links.each do |link|
        download_page = msft.get_download_page(link)
        download_links = msft.get_download_links(download_page.body)
        if regex
          filtered_links = download_links.select { |l| Regexp.new(regex) === l }
          link_collector.concat(filtered_links)
        else
          link_collector.concat(download_links)
        end
      end

      link_collector
    end

    # Performs a search via Google
    #
    # @param keyword [String] The keyword to search
    # @param api_key [String] Google API key
    # @param cx [String] Google Search Engine Key
    # @return [Array<String>] See MicrosoftPatchFinder::GoogleMsbSearch#find_msb_numbers
    def google_search(keyword, api_key, cx)
      search = MicrosoftPatchFinder::GoogleMsbSearch.new(api_key: api_key, search_engine_id: cx)
      search.find_msb_numbers(keyword)
    end


    # Performs a search via Technet
    #
    # @param keyword [String] The keyword to search
    # @return [Array<String>] See MicrosoftPatchFinder::TechnetMsbSearch#find_msb_numbers
    def technet_search(keyword)
      search = MicrosoftPatchFinder::TechnetMsbSearch.new
      search.find_msb_numbers(keyword)
    end

    def run
      links       = []
      msb_numbers = []
      keyword     = args[:keyword]
      regex       = args[:regex] ? args[:regex] : nil
      api_key     = args[:google_api_key]
      cx          = args[:google_search_engine_id]

      case args[:search_engine]
      when :technet
        print_debug("Searching advisories that include #{keyword} via Technet")
        msb_numbers = technet_search(keyword)
      when :google
        print_debug("Searching advisories that include #{keyword} via Google")
        msb_numbers = google_search(keyword, api_key, cx)
      end

      print_debug("Advisories found (#{msb_numbers.length}): #{msb_numbers * ', '}") unless msb_numbers.empty?

      return if args[:dryrun]

      msb_numbers.each do |msb|
        print_debug("Finding download links for #{msb}")
        links.concat(get_download_links(msb, regex))
      end

      unless links.empty?
        print_status "Found these links:"
        print_line links * "\n"
        print_status "Total downloadable updates found: #{links.length}"
      end
    end

    attr_reader :args
  end
end


if __FILE__ == $PROGRAM_NAME
  mod = MicrosoftPatchFinder::Driver.new
  begin
    mod.run
  rescue Interrupt
    $stdout.puts
    $stdout.puts "Good bye"
  end
end

=begin
TODO:
  * Make a gem
  * Make it generic in order to manage different kind of patches and providers
  * Multithreading
=end