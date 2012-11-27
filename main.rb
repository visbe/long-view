# © Copyright IBM Corporation 2011.
# 
require 'rubygems'
require 'net/http'
require 'sinatra'
require 'cgi'
require 'uri'
require 'json'
require 'system_timer'
require 'redis'
require 'logger'
$LOAD_PATH << './src'
require 'NYTSearchAPI.rb'

# Set up logs for tracking request information (warnings, errors, timing for article requests)
# and user tracking info (article clicks, feedback, requests)
#
configure do
	RequestLog = Logger.new('logs/nyt-timelines-requests-log.txt','daily')
	RequestLog.level = Logger::DEBUG
	UserTrackingLog = Logger.new('logs/nyt-timelines-user-tracking-log.txt','daily')
	UserTrackingLog.level = Logger::DEBUG
end


# Returns about page with random user id for tracking behavior
#
get '/' do
	length = 28
	@random_user_id = (0..length).map{ rand(36).to_s(36) }.join
	@server = request.env['HTTP_HOST']
	erb :about
end

# Load javascript file with proper server info
#
get '/js' do
	@server = request.env['HTTP_HOST']
	erb :"thelongview.js"
end

# Called by getArticleText in thelongview.js
# Sets in motion the article text parsing, NLP analysis, NYT API calls, and json reponse object formatting
#
get '/single_article' do
		
	@redis = Redis.new(:host => "localhost", :port => 6379)
	@main_url = params[:url].split("?")[0] #this the article that was being read when the bookmarklet was clicked
	@count = 0 #keeps track of how many API calls have been, so you can throttle them if there are too many
	
		
	# Called after all articles have been retrieved from the NYT API
	# @params: searchHash - search terms -> list of articles returned from API
	# deletes any articles that have already appeared in a different search term articles list
	# also deletes "the listings" articles because there a million of them and they aren't very "related" to article content
	# Returns the original searchHash minus the duplicated articles and 'the listings'
	#
	def dedupe(searchHash)
		uniq_results = Hash.new(0)
		deleted = Hash.new(0)
		searchHash.each{ |k,v|
			v['results'].delete_if { |i|
				begin
					i['title'].strip!
					i['title'].downcase!
					title = i['title']
					uniq_results[title] = uniq_results[title]+1
					(uniq_results[title] > 1) | (title.downcase.include? "the listings") 
				rescue
					RequestLog.warn $! #this will capture, for example, an instance where the article object has no title
				end
			}
		}
		return searchHash
	end
	
	
	# Called for each search term pair returned from the Werkzog sever
	# queries the NYT Article API (via NYTSearchAPI.rb) until it has collect either 3 offsets of results
	# or the max number of offsets received (if less than 3). 
	# See http://developer.nytimes.com/docs/read/article_search_api for definition of offsets, etc
	# Creates a json object containing all search term -> article lists hashes, and then caches the result
	# in Redis
	# Returns this json object
	#
	def query(term)
		cleanTerm = URI.escape('"'+term+'"')
		params = { 	'type' => 'nyt_data', 'searchTerms' =>  cleanTerm }
		offset = 0
		offset_max = 2
		querying = true
		offsets_selected = [0]
		
		results = Array.new()
		
		while querying == true do
			if offset == offset_max or (offset == offsets_selected.length-1 and offset!=0)
				querying = false
			end
			offsets_selected[offset]
			new_query = ImportNews.new(params,offsets_selected[offset],@main_url,RequestLog)
			new_results = new_query.Query()
			results = results | new_results			
			
			# Using the total attribute returned in the query, figure out the number of offest pages
			# and set the offsets_selected array to either 0 through offset_max or 0 through the
			# the total number of offset pgaes for the query, if it's smaller than offset_max
			#
			total = new_query.total
			if total == nil then total = 1 end
			offsets = total.fdiv(10).ceil-1
			offsets_selected = offsets>offset_max ? [0..offset_max] : [0..offsets]
			offset+=1	
			
			# Some pausing to satisfy the NYT API 
			@count+=1
			if @count%10==0
				sleep(1)
			end
		end
		
		if results.length>0 and results[0]!='NYT_DOWN'
			result_json = {'status' => 'ok', 'term' => term, 'total' => total, 'results' => results}
			@redis.set term, result_json.to_json
			@redis.expire term, 84600 #expire in 24 hours
		elsif results[0]=='NYT_DOWN'
			result_json = {'status' => results[0]}
		else
			result_json = {'status' => 'No Results for '+term.to_s}
		end
		
		return result_json
	end
	
	RequestLog.info "Ruby Started: "+@main_url

	# Send @main_url to Werkzog server to retrieve the search terms that will be used in querying 
	url = "http://127.0.0.1:5000/?url="+URI.escape(@main_url, Regexp.new("[^#{URI::PATTERN::UNRESERVED}]"))
	resp = Net::HTTP.get_response(URI.parse(url))
	searchTerms = JSON.parse(resp.body)
	
	# Using the shuffled list of search terms received from Werkzog, query NYT API until you have 5 good result sets
	@similars = Hash.new()
	searchHash = Hash.new()
	term_pairs_max = 5
	term_count = 0
	begin
		if searchTerms.length > term_pairs_max #make sure you have enough search terms to get a full set
			while term_count < term_pairs_max
				term = searchTerms.shift[1] #the 0 item is a Redis artifact
				
				# Check Redis to see if there cached articles associated with the search term
				if @redis.get term
					searchHash[term] = JSON.parse(@redis.get(term))
					term_count+=1
					RequestLog.debug "Got "+term+" from redis"
				else #if not, query from scratch
					term_results = query(term)
					if term_results['status']=='ok'
						searchHash[term] = term_results
						term_count+=1
					elsif term_results['status']=='NYT_DOWN'
						@similars['status'] = "FAILED"	
						@similars['status_msg'] = "The New York Times Article Search API appears to be down."
						break
					else
						RequestLog.warn term_results['status']
					end
				end
			end
			
			# If you have at least one pair of search term results, delete any articles that appear with
			# more than one search term result
			#
			if term_count>0
				if params[:type]=='by_term'
					searchHash = dedupe(searchHash)
				end
				@similars['status'] = "OK"
				@similars['main'] = searchHash
			elsif @similars.has_key?('status')==false
				@similars['status'] = "NO RESULTS"
				@similars['status_msg'] = "No results were returned."
			end
		else
			@similars['status'] = "NO RESULTS"
			@similars['status_msg'] = "No results were returned."
		end
									
	rescue Exception => e		
		RequestLog.error e.message + " on: " + @main_url.to_s
		@similars['status'] = "FAILED"	
		@similars['status_msg'] = "Something went wrong."	
	end	
	
	# Record request with user id to understand usage
	#
	feedback_hash = {'user_id'=>params['user_id'],'type'=>'article_request','main_url'=>@main_url,
		'status'=>@similars['status'],'search_terms'=>searchHash.keys.join("|")}	
	UserTrackingLog.info feedback_hash.to_json

	RequestLog.info "Ruby Finished: "+@main_url

	# Wrap the response in a callback, because the originating request is cross-domain and uses JSONP
	#
	content_type :json
	if params[:callback] == nil
		"test"+"(["+@similars.to_json+"])"
	else
		params[:callback]+"(["+@similars.to_json+"])"
	end
end


# Called when an article body is clicked on
# Logs click context; could be counted later for click-thru (e.g. user clicks/user requests)
# Redirects to the actual article link
#
get '/click' do	
	user_id = params[:user_id]
	clicked_article = params[:redirect]	
	main_url = params[:main_url]
	search_date = params[:search_date]
	search_terms = params[:search_terms]
	type = 'click'
	
	feedback_hash = {'user_id'=>user_id,'type'=>type,'main_url'=>main_url,'clicked_article'=>clicked_article,
		'search_date'=>search_date,'search_terms'=>search_terms}
	
	UserTrackingLog.info feedback_hash.to_json
	
	redirect params[:redirect]
end


# Called when an either article feedback link or search term feedback link is recorded
# Logs the feedback; could be recorded in Redis for future analysis
#
get '/feedback' do	
	user_id = params[:user_id]
	type = params[:type]	
	value = params[:value]
	feedback = params[:feedback]
	main_url = params[:main_url]
	search_date = params[:search_date]
	extra = params[:extra]
	
	feedback_hash = {'user_id'=>user_id,'type'=>type,'value'=> value,'feedback'=>feedback,'main_url'=>main_url,
		'search_date'=>search_date,'extra'=>extra}
	
	UserTrackingLog.info feedback_hash.to_json
	
end

# Called when an either a search term box is clicked or a decade area is moused over
# Logs the event; could be used to analyze usage of The Long View and improve search term selection or time period emphasis
#
get '/internal_click' do	
	user_id = params[:user_id]
	type = params[:type]	
	value = params[:value]
	main_url = params[:main_url]
	search_date = params[:search_date]
	total_articles = params[:total_articles]
	
	feedback_hash = {'user_id'=>user_id,'type'=>type,'value'=> value,'main_url'=>main_url,'search_date'=>search_date,'total_articles'=>total_articles}
	
	UserTrackingLog.info feedback_hash.to_json
	
end
