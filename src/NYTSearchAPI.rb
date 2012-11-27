# © Copyright IBM Corporation 2011.

require 'net/http'
require 'rubygems'
require 'json'
require 'logger'


# This class makes the individual NYT API call, and collects all returned field/value pairs
# for each article in the response. It returns the result as an array of article objects/hashes.
# ImportNews takes as a parent the logger Application so it can use the same logger instance
# as main.rb
#
class ImportNews

	#Log = Logger.new('logs/nyt-timelines-sinatra-log.txt','daily')
	#Log.level = Logger::DEBUG
	
	attr_accessor :num_results, :params, :offset, :url, :main_url, :total, :log
	
	
	# Sets object variables
	# _params is a hash that, for now, only contains the search terms string
	# _offset is the offset to request
	# _main_url is the url of original article; it's used to strip that article from the results if it comes back
	#
	def initialize(_params,_offset,_main_url,_logger)
		self.params = _params
		self.offset = _offset
		self.main_url = _main_url
		self.log = _logger
		self.url = "http://api.nytimes.com/svc/search/v1/article?offset=#{offset}&query=#{self.params['searchTerms'].to_s}"+
			"&fields=body%2Cbyline%2Cclassifiers_facet%2Ccolumn_facet%2Cdate%2Ctitle%2Curl%2Cword_count"+
			"&rank=closest&api-key=" #configue api key
	end
	
	# Make request to NYT API, collect all fields/values for each article in the result set
	#
	def Query
		def GetResults(_data)			
			data_js = _data['results']
			self.total = _data['total']
			results = Array.new()
			
			data_js.each { |i| 
				pairs = Hash.new()
				if i['url']!=self.main_url
					i.each { |key, value| 
						if key == "fields"
							value.each { |k, v|
								pairs[k.downcase] = v
							}
						elsif key == "tags" || key == "multimedia"
							pairs[key.downcase] = value.to_json
						elsif value.kind_of?(Array) == true
							pairs[key.downcase] = value.join("|")
						else
							pairs[key.downcase] = value
						end
					}
					results.push(pairs)
				end
			}
			return results
		end
	
		resp = Net::HTTP.get_response(URI.parse(self.url))
		begin
			data = JSON.parse(resp.body)
			self.num_results = data['results'].length
			return GetResults(data)
		rescue JSON::ParserError
			self.log.error "JSON ERROR: " + resp.body
			if /Not Found/===resp.body
				return ["NYT_DOWN"]
			else
				return Array.new
			end
		rescue Exception => e
			self.log.error e.message
			return Array.new			
		end
	end
end
