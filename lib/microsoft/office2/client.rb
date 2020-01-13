require 'active_support/time'
require 'oauth2'
require 'microsoft/office2'
require 'microsoft/office2/model'
require 'microsoft/office2/user'
require 'microsoft/office2/users'
require 'microsoft/office2/contact'
require 'microsoft/office2/contacts'
require 'microsoft/office2/event'
require 'microsoft/office2/events'
require 'microsoft/office2/calendars'
module Microsoft
    class Error < StandardError
        class ResourceNotFound < Error; end
        class InvalidAuthenticationToken < Error; end
        class BadRequest < Error; end
        class ErrorInvalidIdMalformed < Error; end
        class ErrorAccessDenied < Error; end
        class Conflict < Error; end
    end
end

class Microsoft::Office2; end

##
# This class provides a client to interface between Microsoft Graph API and ACA Engine. Instances of this class are
# primarily only used for:
#   -
class Microsoft::Office2::Client
    include Microsoft::Office2::Events
    include Microsoft::Office2::Users
    include Microsoft::Office2::Contacts
    include Microsoft::Office2::Calendars

    ##
    # Initialize the client for making requests to the Office365 API.
    # @param [String] client_id The client ID of the application registered in the application portal or Azure
    # @param [String] client_secret The client secret of the application registered in the application portal or Azure
    # @param [String] app_site The site in which to send auth requests. This is usually "https://login.microsoftonline.com"
    # @param [String] app_token_url The token URL in which to send token requests
    # @param [String] app_scope The oauth scope to pass to token requests. This is usually "https://graph.microsoft.com/.default"
    # @param [String] graph_domain The domain to pass requests to Graph API. This is usually "https://graph.microsoft.com"
    def initialize(
            client_id:,
            client_secret:,
            app_token_url:,
            app_site: "https://login.microsoftonline.com",
            app_scope: "https://graph.microsoft.com/.default",
            graph_domain: "https://graph.microsoft.com",
            https_proxy: nil,
            save_token: Proc.new{ |token| User.bucket.set("office-token", token) },
            get_token: Proc.new{ User.bucket.get("office-token", quiet: true) }
        )
        @client_id = client_id
        @client_secret = client_secret
        @app_site = app_site
        @app_token_url = app_token_url
        @app_scope = app_scope
        @graph_domain = graph_domain
        @get_token = get_token
        @save_token = save_token
        @https_proxy = https_proxy
        oauth_options = { site: @app_site,  token_url: @app_token_url }
        oauth_options[:connection_opts] = { proxy: @https_proxy } if @https_proxy
        @graph_client ||= OAuth2::Client.new(
            @client_id,
            @client_secret,
            oauth_options
        )
    end


    protected

    ##
    # Passes back either a stored bearer token for Graph API that has yet to expire or
    # grabs a new token and stores it along with the expiry date.
    def graph_token
        # Check if we have a token in couchbase
        # token = User.bucket.get("office-token", quiet: true)
        token = @get_token.call

        # If we don't have a token
        if token.nil? || token[:expiry] <= Time.now.to_i
            # Get a new token with the passed in scope
            new_token = @graph_client.client_credentials.get_token({
                :scope => @app_scope
            })
            # Save both the token and the expiry details
            new_token_model = {
                token: new_token.token,
                expiry: Time.now.to_i + new_token.expires_in,
            }
            @save_token.call(new_token_model)
            # User.bucket.set("office-token", new_token_model)
            return new_token.token
        else
            # Otherwise, use the existing token
            token[:token]
        end
    end

    ##
    # The helper method that abstracts calls to graph API. This method allows for both single requests and 
    # bulk requests using the $batch endpoint.
    def graph_request(request_method:, endpoints:, data:nil, query:{}, headers:{}, bulk: false)
        if bulk
            uv_request_method = :post
            graph_path = "#{@graph_domain}/v1.0/$batch"
            query_string = "?#{query.map { |k,v| "#{k}=#{v}" }.join('&')}"
            data = {
                requests: endpoints.each_with_index.map { |endpoint, i| { id: i, method: request_method.upcase, url: "#{endpoint}#{query_string}" } }
            }
            query = {}
        else
            uv_request_method = request_method.to_sym
            graph_path = "#{@graph_domain}#{endpoints[0]}"
        end

        headers['Authorization'] = "Bearer #{graph_token}"
        headers['Content-Type'] = ENV['GRAPH_CONTENT_TYPE'] || "application/json"
        headers['Prefer'] = ENV['GRAPH_PREFER'] || "outlook.timezone=\"#{ENV['TZ']}\""

        log_graph_request(request_method, data, query, headers, graph_path, endpoints)

        graph_api_options = { inactivity_timeout: 25000, keepalive: false }
        if @https_proxy
            proxy = URI.parse(@https_proxy)
            graph_api_options[:proxy] = { host: proxy.host, port: proxy.port }
        end

        graph_api = UV::HttpEndpoint.new(@graph_domain, graph_api_options)
        response = graph_api.__send__(uv_request_method, path: graph_path, headers: headers, body: data.to_json, query: query)

        response.value
    end

    # Takes an array of requests and makes them in bulk. Is not limited to the same method or endpoint or params (unlike the above graph_request() ).
    # requests: [
    #    {
    #      id: <string> [UNIQUE],
    #      method: 'get/post/put',
    #      url: <string> [e.g. /users/<email>/events?query=param&$top=999]
    #    }
    #    ...
    # ]
    BULK_CONCURRENT_REQUESTS = 15   # The maximum number of requests Graph API will allow in a single bulk request
    BULK_REQUEST_METHOD = :post
    UV_OPTIONS = { inactivity_timeout: 25000, keepalive: false }
    def raw_bulk_request(all_requests)
        bulk_request_endpoint    = "#{@graph_domain}/v1.0/$batch"
        headers = {
            'Authorization' => "Bearer #{graph_token}",
            'Content-Type'  => "application/json",
            'Prefer'        => "outlook.timezone=\"#{ENV['TZ']}\""
        }

        uv_options = UV_OPTIONS
        if @https_proxy
            proxy = URI.parse(@https_proxy)
            uv_options[:proxy] = { host: proxy.host, port: proxy.port }
        end
        graph_api = UV::HttpEndpoint.new(@graph_domain, uv_options)

        sliced_requests = []
        all_requests.each_slice(BULK_CONCURRENT_REQUESTS) do |some_requests|
            request_body = { requests: some_requests }
            sliced_requests << graph_api.__send__(BULK_REQUEST_METHOD, path: bulk_request_endpoint, headers: headers, body: request_body.to_json, query: {})
        end

        thread = Libuv::Reactor.current
        sliced_responses = thread.all(sliced_requests).value
        all_responses = sliced_responses.map{ |single_bulk_response| JSON.parse(single_bulk_response.body)['responses'] }.flatten
        return all_responses
    end

    def graph_date(date)
        Time.at(date.to_i).utc.iso8601.split("+")[0]
    end

    def log_graph_request(request_method, data, query, headers, graph_path, endpoints=nil)
        #Store the request so that it can be output later IF an error was detected
        @request_info =  "#{request_method} to #{graph_path}"
        @request_info << "Data:\n #{data.to_json}" if data
        @request_info << "Query:\n #{data.to_json}" if query
        @request_info << "Headers:\n #{data.to_json}" if headers
        @request_info << "Endpoints:\n #{data.to_json}" if data
    end

    def check_response(response)
        return if response.status >= 400
        STDERR.puts "GRAPH API ERROR Request:\n #{@request_info}"
        STDERR.puts "\n--------------------------------------------""
        STDERR.puts "GRAPH API ERROR Response:\n #{response}"
        case response.status
        when 400
            if response.dig('error', 'code') == 'ErrorInvalidIdMalformed'
                raise Microsoft::Error::ErrorInvalidIdMalformed.new(response.body)
            else
                raise Microsoft::Error::BadRequest.new(response.body)
            end
        when 401
            raise Microsoft::Error::InvalidAuthenticationToken.new(response.body)
        when 403
            raise Microsoft::Error::ErrorAccessDenied.new(response.body)
        when 404
            raise Microsoft::Error::ResourceNotFound.new(response.body)
        when 409
            raise Microsoft::Error::Conflict.new(response.body)
        when 412
            raise Microsoft::Error::Conflict.new(response.body)
        end
    end

end
