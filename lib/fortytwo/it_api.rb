require 'active_support/time'
require 'uv-rays'
require 'json'

module Fortytwo; end;

class Fortytwo::ItApi
    def initialize(
            client_id:,
            client_secret:,
            auth_domain:,
            api_domain:
        )
        @api_domain = api_domain
        oauth_options = {
            site: auth_domain,
            token_url: "#{auth_domain}token"
        }
        @api_client ||= OAuth2::Client.new(
            client_id,
            client_secret,
            oauth_options
        )
    end

    def api_request(request_method:, endpoint:, data:nil, query:{}, headers:nil)
        headers = Hash(headers)
        query = Hash(query)
        # Convert our request method to a symbol and our data to a JSON string
        request_method = request_method.to_sym
        data = data.to_json if !data.nil? && data.class != String

        headers['Authorization'] = "Bearer #{api_token}"
        headers['Content-Type'] = "application/json"

        api_path = "#{@api_domain}#{endpoint}"

        log_api_request(request_method, data, query, headers, api_path)


        api_options = {inactivity_timeout: 25000, keepalive: false}

        api = UV::HttpEndpoint.new(@api_domain, api_options)
        response = api.__send__(request_method, path: api_path, headers: headers, body: data, query: query)

        start_timing = Time.now.to_i
        response_value = response.value
        end_timing = Time.now.to_i
        return response_value
    end

    def log_api_request(request_method, data, query, headers, graph_path)
        STDERR.puts "--------------NEW GRAPH REQUEST------------"
        STDERR.puts "#{request_method} to #{graph_path}"
        STDERR.puts "Data:"
        STDERR.puts data if data
        STDERR.puts "Query:"
        STDERR.puts query if query
        STDERR.puts "Headers:"
        STDERR.puts headers if headers
        STDERR.puts '--------------------------------------------'
        STDERR.flush
    end

    def get_users(q: nil, limit: 100, org_ids:nil, emails:nil)
        # If we have a query and the query has at least one space
        if q && q.include?(" ")
            # Split it into word tokens
            queries = q.split(" ")
            filter_params = []
            # For each word, create a filtering statement
            queries.each do |q|
                filter_params.push("(startswith(firstName,'#{q}') or startswith(lastName,'#{q}') or startswith(email,'#{q}'))")
            end
            # Join these filtering statements using 'or' and add accountEnabled filter
            filter_param = filter_params.join(" and ")
        elsif q && !q.include?(" ")
            filter_param = "startswith(firstName,'#{q}') or startswith(lastName,'#{q}') or startswith(email,'#{q}')"
        elsif org_ids
            filter_param = "organisation/externalId in ('#{org_ids.join('\',\'')}')"
        elsif emails
            filter_param = "email in ('#{emails.join('\',\'')}')"
        end
        query_params = {
            '$top': limit,
            '$expand': 'organisation'
        }
        query_params['$filter'] = filter_param if defined? filter_param
        query_params.compact!
        response = api_request(request_method: 'get', endpoint: 'user', query: query_params)
        JSON.parse(response.body)['value']
    end

    def get_orgs(q: nil, limit: 100, ids:nil)
        # If we have a query and the query has at least one space
        if q && q.include?(" ")
            # Split it into word tokens
            queries = q.split(" ")
            filter_params = []
            # For each word, create a filtering statement
            queries.each do |q|
                filter_params.push("(startswith(name,'#{q}') or startswith(description,'#{q}') or startswith(url,'#{q}'))")
            end
            # Join these filtering statements using 'or' and add accountEnabled filter
            filter_param = filter_params.join(" and ")
        elsif q && !q.include?(" ")
            filter_param = "startswith(name,'#{q}') or startswith(description,'#{q}') or startswith(url,'#{q}')"
        elsif ids
            filter_param = "externalId in ('#{ids.join('\',\'')}')"
        end
        query_params = {
            '$top': limit
        }
        query_params['$filter'] = filter_param if defined? filter_param
        query_params.compact!
        response = api_request(request_method: 'get', endpoint: 'org', query: query_params)
        JSON.parse(response.body)['value']
    end


    def get_visitors(owner_id: nil, limit: 100)
        # If we have a query and the query has at least one space
        query_params = {
            '$top': limit
        }
        if owner_id
            query_params['$filter'] = "Bookers/any(b:b eq '#{owner_id}')"
        end
        query_params['$filter'] = filter_param if defined? filter_param
        response = api_request(request_method: 'get', endpoint: 'visitor', query: query_params)
        JSON.parse(response.body)['value']
    end

    def add_visitor(owner_id:, visitor_object:)
        # If we have a query and the query has at least one space
        query_params = {
            'bookerExternalId': owner_id
        }
        response = api_request(request_method: 'post', endpoint: 'visitor', query: query_params, data: visitor_object)
        JSON.parse(response.body)
    end

    def send_sms(to:, body:, from:'Concierge')
        # Change to aussie number
        if to[0] == '0'
            to = '+61' + to[1..-1]
        end

        # If we have a query and the query has at least one space
        sms_object = {
            'to': to,
            'from': from,
            'body': body
        }
        response = api_request(request_method: 'post', endpoint: 'sms', data: sms_object)
        JSON.parse(response.body)
    end


    protected

    def api_token
        # Get the token
        token = User.bucket.get("fortytwo-token", quiet: true)
        if token.nil? || token[:expiry] <= Time.now.to_i
            # Get a new token and save it
            new_token = @api_client.client_credentials.get_token
            new_token_model = {
                token: new_token.token,
                expiry: Time.now.to_i + new_token.expires_in,
            }
            User.bucket.set("fortytwo-token", new_token_model)
            return new_token.token
        else
            # Use the existing token
            token[:token]
        end
    end
end
