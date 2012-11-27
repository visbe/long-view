# © Copyright IBM Corporation 2011.

import sys,re,nltk
import operator
import random
import time
import json
import urllib
from urllib import urlopen
from BeautifulSoup import BeautifulSoup
from nltk.collocations import *
from nltk.corpus import stopwords 

# NLTK's basic english stop words aren't that extensive, so I add a few of my own
#
ignored_words = stopwords.words('english')
my_ignored_words = ['said','mr.','none','however','new','within']
ignored_words.extend(my_ignored_words)


# Keyword_Getter parses an article's text, retreived named entities and significant terms,
# records these in Redis, as well as returning them.
#
class Keyword_Getter:

	# Uses NLTK to return the top 5 significant terms that occur more than 2 times and are greater than 3 characters long.
	# The scoring function (bigram_measures.pmi) is a bit arbitrary. Some part of nltk.collocations
	# needs to be trained in order to get the differences between different scoring functions 
	# (e.g. pmi, chi_sq, likelihood ratio, etc)
	# See http://nltk.googlecode.com/svn/trunk/doc/api/nltk.metrics.association.NgramAssocMeasures-class.html
	#
	def get_ngrams(self,text):		
		bigram_measures = nltk.collocations.BigramAssocMeasures()
		tokens = nltk.word_tokenize(text)
		finder = BigramCollocationFinder.from_words(tokens)
		finder.apply_freq_filter(2)
		finder.apply_word_filter(lambda w: len(w) < 3 or w.lower() in ignored_words)
		
		ngrams = finder.nbest(bigram_measures.pmi, 5) 
		names=[]
		for word in ngrams:
			names.append(' '.join(word).lower())
		return names
	
	# Uses NLTK to return top 8 named entities -- person, organization, location, gpe (a specific kind of location),
	# and facility. This step can take up to 10 seconds, so may be worth optimizing at some point.
	# 
	def get_named_entities(self,text):
		sentences = nltk.sent_tokenize(text)
		sentences = [nltk.word_tokenize(sent) for sent in sentences]
		sentences = [nltk.pos_tag(sent) for sent in sentences] #takes 3ish seconds
		nes = nltk.batch_ne_chunk(sentences,binary=False) #takes 2ish seconds
		named_entities = {}
		stop_names = ['Mr.']
		
		# Loop through the tagged sentences, looking for named entites, and put their "leaves" together
		# e.g. "White" + " " + "House"
		#
		for i in nes:
			for j in i:
				if re.search('PERSON|ORGANIZATION|LOCATION|GPE|FACILITY',str(j)):
					name = ' '.join(c[0] for c in j.leaves())
					
					# Attempt to merge people names if you've seen them before
					# e.g. Ms. Clinton gets merged into Hillary Clinton
					if not (name in stop_names):
						regex = re.compile(r'^'+name.split(' ')[-1]+'|\s'+name.split(' ')[-1]+'$')
						regex_match = filter(regex.search,named_entities.keys())
						if (name in named_entities):
							named_entities[name]+=1
						elif  (len(regex_match)>0 and re.search('PERSON',str(j))!=None):
							named_entities[regex_match[0]]+=1
						else:
							named_entities[name] = 1
		
		# Sort named entities by count and take first 8
		sorted_names = sorted(named_entities.iteritems(), key=operator.itemgetter(1), reverse=True)
		names=[]
		for name in sorted_names[:8]:
			names.append(name[0].lower())		
		return names
	
	# Scrape text of article using url. file_type is usually set to "html", but could be "text" if you
	# wanted to text with a random sample of text.
	# Returns the text of the article, minus html formatting and unicode characters
	#
	def get_text(self,file_type,url):
		if file_type=='html':
			url = url.split("?")[0].rstrip('/')+"?pagewanted=all"
			html = urlopen(urllib.unquote(url)).read()
			soup = BeautifulSoup(html)
			
			# Blogs and news articles have slightly different html layouts, so we need to parse them differently
			#if re.search("blogs.",url) is None:
			#	divs = soup.findAll('div',{'class':'articleBody'})
			#	if len(divs)==0:
			#		divs = soup.findAll('div',{'id':'articleBody'}) # articleBody as an id is an older convention on NYT
			#else:
			#	divs = soup.findAll('div',{'class':re.compile(r'post|mod-articletext|nytint-post|entry-content')})[0].findAll('p')
			divs = soup.findAll('div',{'class':re.compile(r'articleBody|post|mod-articletext|nytint-post|entry-content')})
			if len(divs)==0:
				divs = soup.findAll('div',{'id':'articleBody'}) # articleBody as an id is an older convention on NYT
			
			newBody = nltk.clean_html(divs.__str__())
			cleanBody =  re.sub(r'&rsquo|&rdquo|&ldquo|&lsquo|&mdash','',newBody)
		else:
			cleanBody = url
		return cleanBody
	
	# Main function that calls the earlier cleaning/parsing functions.
	# Keep only unique names/bigrams, in case "Hillary Clinton" comes back in both get_ngrams and get_named_entites
	# Returns an array of search term pairs, formatted for the later NYT query, 
	# e.g. '"White House"+"Hillary Clinton"'
	#
	def keywords(self):
		print "Started get_text for "+self.url+" at:"+str(time.time())
		text = self.get_text(self.file_type,self.url)
		print "Started get_ngrams "+self.url+" at:"+str(time.time())
		bigrams = set(self.get_ngrams(text))
		print "Started get_named_entities "+self.url+" at:"+str(time.time())
		names = set(self.get_named_entities(text))
		search_set = list(bigrams.union(names)) 
		
		search_pairs = []
		for i in search_set:
			for j in search_set[search_set.index(i):]:
				if i !=j:
					search_pairs.append('"'+str(i)+'"+"'+str(j)+'"');
		
		print "Returned search pairs "+self.url+" to NLTK_Server at:"+str(time.time())

		return search_pairs
	
	# file_type is "html" if the request comes from the Sinatra server
	# url is the url of the article being viewed
	#
	def __init__(self,file_type,url):
		self.file_type = file_type
		self.url = url
		


