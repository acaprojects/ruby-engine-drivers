require 'jwt'

module Floorsense; end

# Documentation: https://documenter.getpostman.com/view/8843075/SVmwvctF?version=latest#3bfbb050-722d-4433-889a-8793fa90af9c

class Floorsense::Desks
    include ::Orchestrator::Constants
    include ::Orchestrator::Transcoder

    # Discovery Information
    implements :service
    descriptive_name 'Floorsense Desk Tracking'
    generic_name :DeskManagement

    # HTTP keepalive
    keepalive false

    default_settings({
        username: "srvc_acct",
        password: "password!"
    })

    def on_load
        @auth_token = ''
        @auth_expiry = 1.minute.ago
        on_update
    end

    def on_update
        username = setting(:username)
        password = setting(:password)
        @credentials = URI.encode_www_form("username" => username, "password" => password)

        # { "floor_id" => "zone_id" }
        @floor_mappings = setting(:floor_mappings)
    end

    def expire_token!
        @auth_expiry = 1.minute.ago
    end

    def token_expired?
        @auth_expiry < Time.now
    end

    def get_token
        return @auth_token unless token_expired?

        response = post("/restapi/login", body: @credentials, headers: {
            "Content-Type" => "application/x-www-form-urlencoded",
            "Accept"       => "application/json"
        }).value

        data = response.body
        logger.debug { "received login response #{data}" }

        if (200...300).include?(response.status)
            resp = JSON.parse(data, symbolize_names: true)
            token = resp[:info][:token]
            payload, header = JWT.decode(token, nil, false)
            @auth_expiry = (Time.at payload["exp"]) - 5.minutes
            @auth_token = "Bearer #{token}"
        else
            case response.status
            when 401
                resp = JSON.parse(data, symbolize_names: true)
                logger.warn "#{resp[:message]} (#{resp[:code]})"
            else
                logger.error "authentication failed with HTTP #{response.status}"
            end
            raise "failed to obtain access token"
        end
    end

    def desks(group_id)
        token = get_token
        uri = "/restapi/floorplan-desk?planid=#{group_id}"

        response = get(uri, headers: {
            "Accept" => "application/json",
            "Authorization" => token
        }).value

        if (200...300).include?(response.status)
            resp = JSON.parse(response.body, symbolize_names: true)
            resp[:info]
        else
            expire_token! if response.status == 401
            raise "unexpected response #{response.status}\n#{response.body}"
        end
    end

    def locate(user)
        token = get_token
        uri = "/restapi/user-locate?name=#{URI.encode_www_form_component user}"

        response = get(uri, headers: {
            "Accept" => "application/json",
            "Authorization" => token
        }).value

        if (200...300).include?(response.status)
            resp = JSON.parse(response.body, symbolize_names: true)
            # Select users where there is a desk key found
            resp[:info].select { |user| user[:key] }
        else
            expire_token! if response.status == 401
            raise "unexpected response #{response.status}\n#{response.body}"
        end
    end
end
