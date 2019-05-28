require 'active_support/time'
require 'uv-rays'
require 'json'

module Microsoft
    class Error < StandardError
        class ResourceNotFound < Error; end
        class InvalidAuthenticationToken < Error; end
        class BadRequest < Error; end
        class ErrorInvalidIdMalformed < Error; end
        class ErrorAccessDenied < Error; end
    end
end

class Microsoft::Skype
    def initialize(
            domain:,
            client_id:,
            client_secret:,
            username:,
            password:,
            logger: nil
        )
        @domain = domain
        @username = username
        @password = password
        @client_id = client_id
        @client_secret = client_secret
        @logger = logger
    end

    def create_meeting(subject)
        users_url = discover_user_url
        user_token = get_token(users_url)

        apps_url = discover_application_url(users_url, user_token)
        app_token = get_token(apps_url)

        apps_headers = {
            "Accept" => "application/json",
            "Content-Type" => "application/json",
            "Authorization" => "Bearer #{app_token}"
        }

        meetings_url = discover_meeting_url(apps_url, apps_headers, app_token)

        apps_uri = URI(apps_url)
        base_url = "#{apps_uri.scheme}://#{apps_uri.host}"
        create_skype_meeting(base_url, meetings_url, apps_headers, subject)
    end

    protected

    def get_token(url)
        uri = URI(url)
        resource = "#{uri.scheme}://#{uri.host}"
        token_uri = URI("https://login.microsoftonline.com/#{@domain.split('.').first}.onmicrosoft.com/oauth2/token")
        params = {resource: resource, client_id: @client_id, grant_type: "password",
                  username: @username, password: @password, client_secret: @client_secret}

        @logger&.debug {
            "Requesting token from #{token_uri}\nwith params:\n#{params}"
        }

        auth_response = nil
        ::Libuv.reactor {
            skype_auth_api = UV::HttpEndpoint.new(token_uri, {inactivity_timeout: 25000, keepalive: false})
            request = skype_auth_api.post({path: token_uri, body: params, headers: {"Content-Type":"application/x-www-form-urlencoded"}})
            auth_response = request.value
        }
        JSON.parse(auth_response.body)["access_token"]
    end

    def discover_user_url
        discover_response = nil
        ::Libuv.reactor {
            @skype_domain = "http://lyncdiscover.#{@domain}"
            skype_discover_api = ::UV::HttpEndpoint.new(@skype_domain, {inactivity_timeout: 25000, keepalive: false})
            discover_request = skype_discover_api.get
            discover_response = discover_request.value
        }
        r = ::JSON.parse(discover_response.body)
        r["_links"]["user"]["href"]
    end

    def discover_application_url(users_url, user_token)
        users_headers = {
            "Accept" => "application/json",
            "Content-Type" => "application/json",
            "Authorization" => "Bearer #{user_token}"
        }

        # GET to users_url
        user_response = nil
        ::Libuv.reactor {
            skype_users_api = UV::HttpEndpoint.new(users_url, {inactivity_timeout: 25000, keepalive: false})
            user_request = skype_users_api.get({
                path: users_url,
                headers: users_headers
            })
            user_response = user_request.value
        }
        full_auth_response = JSON.parse(user_response.body)
        full_auth_response["_links"]["applications"]["href"]
    end

    def discover_meeting_url(apps_url, apps_headers, app_token)
        body = {Culture: 'en-us', EndpointId: @client_id, UserAgent: 'Ruby ACA Engine'}
        apps_response = nil
        ::Libuv.reactor {
            skype_apps_api = UV::HttpEndpoint.new(apps_url, {inactivity_timeout: 25000, keepalive: false})
            apps_request = skype_apps_api.post({
                path: apps_url,
                headers: apps_headers,
                body: body.to_json
            })
            apps_response = apps_request.value
        }
        app = JSON.parse(apps_response.body)
        app["_embedded"]["onlineMeetings"]["_links"]["myOnlineMeetings"]["href"]
    end

    def create_skype_meeting(base_url, meetings_url, apps_headers, subject)
        body = {accessLevel: "Everyone", subject: subject}
        url = base_url + meetings_url

        meeting_response = nil
        ::Libuv.reactor {
            skype_auth_api = UV::HttpEndpoint.new(url, {inactivity_timeout: 25000, keepalive: false})
            meeting_request = skype_auth_api.post({path: url, body: body.to_json, headers: apps_headers})
            meeting_response = meeting_request.value
        }
        ::JSON.parse(meeting_response.body)['joinUrl']
    end
end
