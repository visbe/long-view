# © Copyright IBM Corporation 2011.

import os,sys
cmd_folder = os.path.dirname(os.path.abspath(__file__))
if cmd_folder not in sys.path:
     sys.path.insert(0, cmd_folder)
import redis
import urlparse
import json
import random
from random import shuffle
from werkzeug.wrappers import Request, Response
from werkzeug.routing import Map, Rule
from werkzeug.exceptions import HTTPException, NotFound
from werkzeug.wsgi import SharedDataMiddleware
from werkzeug.utils import redirect
from mm_keyword import keyword_getter

# NLTK_Server creates a Redis connection, handles incoming requests, and returns responses
#
class NLTK_Server(object):

    def __init__(self, config):
        self.redis = redis.Redis(config['redis_host'], config['redis_port'])

	#dispatch_request gets the url parameter from an incoming request.
	#It checks to see if that url exists in Redis. If it doesn't, it retrieves 
	#a set of search pairs using keyword_getter. Regardless, it randomly orders the
	#list of search pairs, and creates a json object containing this re-order list.
	#It returns this list to process that requested it; in this case the sinatra server.
	#
    def dispatch_request(self, request):
		url = request.args.get('url')
		search_pairs = self.redis.get(url)
		if search_pairs is None:
			k = keyword_getter.Keyword_Getter('html',url)
			search_pairs = k.keywords()
			self.redis.set(url,json.dumps(search_pairs))
		else:
			search_pairs = json.loads(search_pairs)
		final_set = {}
		shuffle(search_pairs)
		for i in search_pairs:
			final_set[search_pairs.index(i)] =i
		print search_pairs
		return Response(json.dumps(final_set))
		
	#Basic set up for the Werkzeug server; sets response content-type to json
	#
    def wsgi_app(self, environ, start_response):
        request = Request(environ)
        response = self.dispatch_request(request)
        response.headers['content-type'] = 'application/json'
        return response(environ, start_response)

    def __call__(self, environ, start_response):
        return self.wsgi_app(environ, start_response)

#Define Redis server
#
def create_app(redis_host='localhost', redis_port=6379):
    app = NLTK_Server({
        'redis_host':       redis_host,
        'redis_port':       redis_port
    })
    return app

#Starts Werkzeug server the first time this script is run
#
if __name__ == '__main__':
    from werkzeug.serving import run_simple
    app = create_app()
    run_simple('127.0.0.1', 5000, app, use_debugger=True, use_reloader=True)