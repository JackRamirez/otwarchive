# Parse stories from other websites and uploaded files, looking for metadata to harvest
# and put into the archive.
#
class StoryParser
  require 'timeout'
  require 'hpricot'
  require 'nokogiri'
  require 'mechanize'
  require 'open-uri'
  include HtmlFormatter

  META_PATTERNS = {:title => 'Title',
                   :notes => 'Note',
                   :summary => 'Summary',
                   :freeform_string => "Tag",
                   :fandom_string => "Fandom",
                   :rating_string => "Rating",
                   :pairing_string => "Pairing",
                   :published_at => 'Date|Posted|Posted on|Posted at'
                   }
  
  # These attributes need to be moved from the work to the chapter                 
  CHAPTER_ATTRIBUTES = [:published_at]
  
  # These lists will stop with the first one it matches, so put more-specific matches
  # towards the front of the list.

  # places for which we have a custom parse_story_from_[source] method
  # for getting information out of the downloaded text
  KNOWN_STORY_PARSERS = %w(lj yuletide ffnet)
  
  # places for which we have a custom parse_author_from_[source] method
  # which returns an external_author object including an email address
  KNOWN_AUTHOR_PARSERS= %w(yuletide)

  # places for which we have a download_story_from_[source]
  # used to customize the downloading process
  KNOWN_STORY_LOCATIONS = %w(lj)

  # places for which we have a download_chaptered_from
  # to get a set of chapters all together
  CHAPTERED_STORY_LOCATIONS = %w(ffnet)

  # regular expressions to match against the URLS
  SOURCE_LJ = '(live|dead|insane)?journal(fen)?\.com'
  SOURCE_YULETIDE = 'yuletidetreasure\.org'
  SOURCE_FFNET = 'fanfiction\.net'

  # time out if we can't download fast enough
  STORY_DOWNLOAD_TIMEOUT = 60
  MAX_CHAPTER_COUNT = 200


  # Import many stories
  def import_from_urls(urls, options = {})    
    # Try to get the works
    temp_works = []
    saved_works = []
    failed_urls = []
    urls.each do |url|
      begin
        work = download_and_parse_story(url)
        if options[:importing_for_others]
          # try and create external authors for any of these works
          if (external_author = parse_author(url))
            work.external_authors << external_author
          end
        end
        temp_works << work
      rescue
        failed_urls << url
      end
    end

    # For whichever works succeeded, we now attempt to save
    temp_works.each do |work|
      # set default values for required tags for any works that don't have them
      work.fandom_string = ArchiveConfig.FANDOM_NO_TAG_NAME if work.fandoms.empty?
      work.rating_string = ArchiveConfig.RATING_DEFAULT_TAG_NAME if work.ratings.empty?
      work.warning_strings = ArchiveConfig.WARNING_DEFAULT_TAG_NAME if work.warnings.empty?

      # set authors for the works
      pseuds = []
      pseuds << @current_user.default_pseud if defined? @current_user
      pseuds += options[:pseuds] if options[:pseuds]

      pseuds.each do |pseud| 
        work.pseuds << pseud
        work.chapters.each {|chapter| chapter.pseuds << pseud}
      end
      
      if options[:post_automatically]
        work.posted = true
        work.chapters.each do |chapter|
          chapter.save
        end
      end
      
      if work.save
        saved_works << work
      else
        failed_urls << work.imported_from_url
        work.delete
      end
    end
    return [saved_works, failed_urls]
  end

  # Downloads a story and passes it on to the parser.
  # If the URL of the story is from a site for which we have special rules
  # (eg, downloading from a livejournal clone, you want to use ?format=light
  # to get a nice and consistent post format), it will pre-process the url
  # according to the rules for that site.
  def download_and_parse_story(location)
    source = get_source_if_known(CHAPTERED_STORY_LOCATIONS, location)
    if source.nil?
      story = download_text(location)
      return parse_story(story, location)
    else
      return download_and_parse_chaptered_story(source, location)
    end
  end

  # Given an array of urls for chapters of a single story, 
  # download them all and combine into a single work
  def download_and_parse_chapters_into_story(locations)
    chapter_contents = []
    locations.each do |location|
      chapter_contents << download_text(location)
    end
    return parse_chaptered_story(locations.first, chapter_contents)
  end

  def download_and_parse_chapter(location)
    story = download_text(location)
    return parse_chapter(story, location)
  end

  # Parses the text of a story, optionally from a given location.
  def parse_story(story, location = nil)
    work_params = parse_common(story, location)
    work_params = sanitize_params(work_params)
    
    # move any attributes from work to chapter if necessary
    CHAPTER_ATTRIBUTES.each do |attrib|
      if work_params[attrib]
        work_params[:chapter_attributes][attrib] = work_params[attrib]
        work_params.delete(attrib)
      end
    end
    
    return set_work_attributes(Work.new(work_params), location)
  end

  # Parses text but returns a chapter instead
  def parse_chapter(chapter, location = nil)
    work_params = parse_common(chapter, location)
    work_params = sanitize_params(work_params)
    chapter = get_chapter_from_work_params(work_params)
    return chapter
  end
  
  # tries to create the external author for a given url
  def parse_author(location)
    source = get_source_if_known(KNOWN_AUTHOR_PARSERS, location)
    if !source.nil?
      return eval("parse_author_from_#{source.downcase}(location)")
    end
    
  end

  # Everything below here is protected and should not be touched by outside
  # code -- please use the above functions to parse stories.

  protected
  
    def parse_author_from_yuletide(location)
      #debugger
      external_author = nil
      if location.match(/archive\/([0-9]+\/.*)\.html/)
        yuletide_location = $1
        archive_url = "http://yuletidetreasure.org/cgi-bin/files/get_author.cgi?filename=#{yuletide_location}"
        author_info = download_text(archive_url)
        if author_info.match(/^EMAIL: (.*)$/) 
          email = $1
          external_author = ExternalAuthor.find_or_create_by_email(email)
          if author_info.match(/^NAME: (.*)/) 
            name = $1 
            external_author_name = ExternalAuthorName.find(:first, :conditions => {:name => name, :external_author_id => external_author.id}) ||
                                    ExternalAuthorName.new(:name => name) 
            external_author.external_author_names << external_author_name
            external_author.save
          end
          return external_author
        end
      end
    end
    
    def set_work_attributes(work, location) 
      work.imported_from_url = location
      work.expected_number_of_chapters = work.chapters.length
      return work
    end

    def download_and_parse_chaptered_story(source, location)
      chapter_contents = eval("download_chaptered_from_#{source.downcase}(location)")
      return parse_chaptered_story(location, chapter_contents)
    end
    
    def parse_chaptered_story(location, chapter_contents)
      work = nil
      work_params = { :title => "UPLOADED WORK", :chapter_attributes => {} }
      chapter_contents.each do |content|
        @doc = Nokogiri.parse(content)
        
        chapter_params = parse_common(content, location)
        if work.nil?
          # create the new work
          work = Work.new(work_params.merge!(chapter_params))
        else
          new_chapter = get_chapter_from_work_params(chapter_params)
          new_chapter.position = work.chapters.length + 1
          new_chapter.posted = true
          work.chapters << new_chapter
        end
      end
      return set_work_attributes(work, location)
    end


    def get_chapter_from_work_params(work_params)
      @chapter = Chapter.new({:content => work_params[:chapter_attributes][:content]})
      chapter_params = work_params.delete_if {|name, param| !@chapter.attribute_names.include?(name.to_s)}
      @chapter.update_attributes(chapter_params)
      return @chapter
    end

    def download_text(location)
      story = ""
      source = get_source_if_known(KNOWN_STORY_LOCATIONS, location)
      if source.nil?
        story = download_with_timeout(location)
      else
        story = eval("download_from_#{source.downcase}(location)")
      end
      story.empty? ? "" : fix_quotes(story)
    end

    # canonicalize the url for downloading from lj or clones
    def download_from_lj(location)
      url = location
      url.gsub!(/\?(.*)$/, "") # strip off any existing params at the end
      url += "?format=light" # go to light format
      text = download_with_timeout(url)
      if text.match(/adult_check/)
        Timeout::timeout(STORY_DOWNLOAD_TIMEOUT) {
          begin
            agent = WWW::Mechanize.new
            form = agent.get(url).forms.first
            page = agent.submit(form, form.buttons.first) # submits the adult concepts form
            text = page.body
          rescue
            text = ""
          end
        }      
      end
      return text
    end

    # grab all the chapters of the story from ff.net
    def download_chaptered_from_ffnet(location)
      @chapter_contents = []
      if location.match(/^(.*fanfiction\.net\/s\/[0-9]+\/)([0-9]+)(\/.*)$/i)
        urlstart = $1
        urlend = $3
        chapnum = 1
        Timeout::timeout(STORY_DOWNLOAD_TIMEOUT) {
          loop do
            url = "#{urlstart}#{chapnum.to_s}#{urlend}"
            body = download_with_timeout(url)
            if body.nil? || chapnum > MAX_CHAPTER_COUNT || body.match(/FanFiction\.Net Message/)
              break
            end
            @chapter_contents << body
            chapnum = chapnum + 1
          end
        }
      end
      return @chapter_contents
    end

    # used to parse either entire story or chapter
    def parse_common(story, location = nil)
      work_params = { :title => "UPLOADED WORK", :chapter_attributes => {:content => ""} }
      @doc = Nokogiri.parse(story) rescue ""

      if !location.nil?
        source = get_source_if_known(KNOWN_STORY_PARSERS, location)
        if !source.nil?
          params = eval("parse_story_from_#{source.downcase}(story)")
          return work_params.merge!(params)
        end
      end
      return work_params.merge!(parse_story_from_unknown(story))
    end

    # our fallback: parse a story from an unknown source, so we have no special
    # rules.
    def parse_story_from_unknown(story)
      work_params = {:chapter_attributes => {}}
      storyhead = @doc.css("head").inner_html if @doc.css("head")
      storytext = @doc.css("body").inner_html if @doc.css("body")
      if storytext.blank?
        storytext = @doc.css("html").inner_html
      end
      if storytext.blank?
        # just grab everything
        storytext = story
      end
      meta = {}
      unless storyhead.blank?
        meta.merge!(scan_text_for_meta(storyhead))
      end
      meta.merge!(scan_text_for_meta(storytext))
      work_params[:title] = @doc.css("title").inner_html
      work_params[:chapter_attributes][:content] = clean_storytext(storytext)
      work_params = work_params.merge!(meta)

      return work_params
    end

    def parse_story_from_lj(story)
      work_params = {:chapter_attributes => {}}

      # in LJ "light" format, the story contents are in the first div
      # inside the body.
      body = @doc.css("body")
      content_divs = body.css("div")
      storytext = !content_divs[0].nil? ? content_divs[0].inner_html : body.inner_html

      # cleanup the text
      # storytext.gsub!(/<br\s*\/?>/i, "\n") # replace the breaks with newlines
      storytext = clean_storytext(storytext)

      work_params[:chapter_attributes][:content] = storytext
      work_params[:title] = @doc.css("title").inner_html # default
      work_params.merge!(scan_text_for_meta(storytext))

      return work_params
    end

    def parse_story_from_yuletide(story)
      work_params = {:chapter_attributes => {}}
      storytext = (@doc/"/html/body/p/table/tr/td[2]/table/tr/td[2]").inner_html
      if storytext.empty?
        storytext = (@doc/"body").inner_html
      end
      storytext = clean_storytext(storytext)

      # fix the relative links
      storytext.gsub!(/<a href="\//, '<a href="http://yuletidetreasure.org/')

      work_params.merge!(scan_text_for_meta(storytext))
      work_params[:chapter_attributes][:content] = storytext
      work_params[:title] = (@doc/"title").inner_html
      work_params[:notes] = (@doc/"/html/body/p/table/tr/td[2]/table/tr/td[2]/center/p").inner_html

      tags = ['yuletide']

      if storytext.match(/Written for: (.*) in the (.*) challenge/i)
        recip = $1
        challenge = $2
        tags << "recipient:#{recip}"
        tags << "challenge:#{challenge}"
      end
      if storytext.match(/<center>.*Fandom:.*Written for:.*by <a .*>(.*)<\/a><br>\n<p>(.*)<\/p><\/center>/ix)
        author = $1
        work_params[:notes] = $2
      end

      # Here we're going to try and get the search results
      begin
        search_title = work_params[:title].gsub(/[^\w]/, ' ').gsub(/\s+/, '+')
        search_author = author.nil? ? "" : author.gsub(/[^\w]/, ' ').gsub(/\s+/, '+')
        search_recip = recip.nil? ? "" : recip.gsub(/[^\w]/, ' ').gsub(/\s+/, '+')
        search_url = "http://www.yuletidetreasure.org/cgi-bin/search.cgi?" +
                      "Recipient=#{search_recip}&Title=#{search_title}&Author=#{search_author}&NumToList=0"
        search_res = download_with_timeout(search_url)
        search_doc = Nokogiri.parse(search_res)
        summary = search_doc.css('dd.summary') ? search_doc.css('dd.summary').first.content : ""
        work_params[:summary] = summary
        work_params.merge!(scan_text_for_meta(search_res))
      rescue
        # couldn't get the summary data, oh well, keep going
      end

      work_params[:freeform_string] = tags.join(ArchiveConfig.DELIMITER)

      return work_params
    end

    def parse_story_from_ffnet(story)
      work_params = {:chapter_attributes => {}}
      storytext = clean_storytext((@doc/"#storytext").inner_html)

      work_params[:notes] = ((@doc/"#storytext")/"p").first.inner_html

      # put in some blank lines to make it readable in the textarea
      # the processing will strip out the extras
      storytext.gsub!(/<\/p><p>/, "</p>\n\n<p>")

      tags = []
      pagetitle = (@doc/"title").inner_html
      if pagetitle && pagetitle.match(/(.*), an? (.*) fanfic - FanFiction\.Net/)
        work_params[:fandom_string] = $2
        work_params[:title] = $1
        if work_params[:title].match(/^(.*) Chapter ([0-9]+): (.*)$/)
          if ($2 == "1")
            # first chapter
            work_params[:title] = $1
            work_params[:chapter_attributes][:title] = $3
          else
            work_params[:title] = $3
          end
        end
      end
      if story.match(/rated:\s*<a.*?>\s*(.*?)<\/a>/i)
        rating = convert_rating($1)
        work_params[:rating_string] = rating
      end

      if story.match(/rated.*?<\/a> - .*? - (.*?)(\/(.*?))? -/i)
        tags << $1
        tags << $3 unless $1 == $3
      end

      work_params[:freeform_string] = tags.join(ArchiveConfig.DELIMITER)
      work_params[:chapter_attributes][:content] = storytext

      return work_params
    end

    # Find any cases of the given pieces of meta in the given text
    # and return a hash
    def scan_text_for_meta(text)
      # break up the text with some extra newlines to make matching more likely
      # and strip out some tags
      text.gsub!(/<br/, "\n<br")
      text.gsub!(/<p/, "\n<p")
      text.gsub!(/<\/?span(.*?)?>/, '')
      text.gsub!(/<\/?div(.*?)?>/, '')

      meta = {}
      metapatterns = META_PATTERNS
      is_tag = {}
      ["fandom_string", "pairing_string", "freeform_string", "rating_string"].each do |c|
        is_tag[c.to_sym] = true
      end
      metapatterns.each do |metaname, pattern|
        # what this does is look for pattern: (whatever)
        # and then sets meta[:metaname] = whatever
        # eg, if it finds Fandom: Stargate SG-1 it will set meta[:fandom] = Stargate SG-1
        # then it runs it through convert_<metaname> for cleanup if such a function is defined (eg convert_rating_string)
        metapattern = Regexp.new("(#{pattern})\s*:\s*(.*)", Regexp::IGNORECASE)
        metapattern_plural = Regexp.new("(#{pattern.pluralize})\s*:\s*(.*)", Regexp::IGNORECASE)
        if text.match(metapattern) || text.match(metapattern_plural)
          value = $2
          value = clean_tags(value) if is_tag[metaname]
          begin
            value = eval("convert_#{metaname.to_s.downcase}(value)")
          rescue NameError
          end
          meta[metaname] = value
        end
      end
      return meta
    end

    def download_with_timeout(location)
      Timeout::timeout(STORY_DOWNLOAD_TIMEOUT) {
        begin
          response = Net::HTTP.get_response(URI.parse(location))
          case response
          when Net::HTTPSuccess
            response.body
          else
           nil
          end
        rescue Errno::ECONNREFUSED
          nil
        end
      }
    end

    def get_last_modified(location)
      Timeout::timeout(STORY_DOWNLOAD_TIMEOUT) {
        resp = open(location)
        resp.last_modified
      }
    end

    def get_source_if_known(known_sources, location)
      known_sources.each do |source|
        pattern = Regexp.new(eval("SOURCE_#{source.upcase}"), Regexp::IGNORECASE)
        if location.match(pattern)
          return source
        end
      end
      nil
    end

    def clean_storytext(storytext)
      return sanitize_whitelist(cleanup_and_format(storytext))
    end

    # works conservatively -- doesn't split on
    # spaces and truncates instead.
    def clean_tags(tags)
      tags = sanitize_fully(tags)
      if tags.match(/,/)
        tagslist = tags.split(/,/)
      else
        tagslist = [tags]
      end
      newlist = []
      tagslist.each do |tag|
        tag.gsub!(/[\*\<\>]/, '')
        tag = truncate_on_word_boundary(tag, ArchiveConfig.TAG_MAX)
        newlist << tag
      end
      return newlist.join(ArchiveConfig.DELIMITER)
    end

    def truncate_on_word_boundary(text, max_length)
      return if text.blank?
      words = text.split()
      truncated = words.first
      if words.length > 1
        words[1..words.length].each do |word|
          truncated += " " + word if truncated.length + word.length + 1 <= max_length
        end
      end
      truncated[0..max_length-1]
    end

    # convert space-separated tags to comma-separated
    def clean_and_split_tags(tags)
      if !tags.match(/,/) && tags.match(/\s/)
        tags = tags.split(/\s+/).join(',')
      end
      return clean_tags(tags)
    end

    # Convert the common ratings into whatever ratings we're
    # using on this archive.
    def convert_rating(rating)
      rating = rating.downcase
      if rating.match(/(nc-?1[78]|x|ma|explicit)/)
        ArchiveConfig.RATING_EXPLICIT_TAG_NAME
      elsif rating.match(/(r|m|mature)/)
        ArchiveConfig.RATING_MATURE_TAG_NAME
      elsif rating.match(/(pg-?1[35]|t|teen)/)
        ArchiveConfig.RATING_TEEN_TAG_NAME
      elsif rating.match(/(pg|g|k+|k|general audiences)/)
        ArchiveConfig.RATING_GENERAL_TAG_NAME
      else
        ArchiveConfig.RATING_DEFAULT_TAG_NAME
      end
    end

    def convert_rating_string(rating)
      return convert_rating(rating)
    end

    def convert_published_at(date)
      Date.parse(date)
    end
    
end
