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
        password: "password!",
        floor_mappings: {
          zone_id: :group_id,
          zone_id: [:group_id, :group_id]
        }
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

        # { "zone_id" => "floor_id" }
        @floor_mappings = setting(:floor_mappings) || {}

        # desk_id => [zone_id, floor_id, cid]
        # cid required for desk status
        @desk_mappings = {}

        schedule.clear
        schedule.in("5s") { fetch_desk_state }
    end

    def expire_token!
        @auth_expiry = 1.minute.ago
    end

    def token_expired?
        @auth_expiry < Time.now
    end

    def get_token
        return @auth_token unless token_expired?

        post("/restapi/login", body: @credentials, headers: {
            "Content-Type" => "application/x-www-form-urlencoded",
            "Accept"       => "application/json"
        }) { |response|
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
        }.value
    end

    def desks(group_id)
        token = get_token
        uri = "/restapi/floorplan-desk?planid=#{group_id}"

        get(uri, headers: {
            "Accept" => "application/json",
            "Authorization" => token
        }) { |response|
            if (200...300).include?(response.status)
                resp = JSON.parse(response.body, symbolize_names: true)
                resp[:info]
            else
                expire_token! if response.status == 401
                raise "unexpected response #{response.status}\n#{response.body}"
            end
        }.value
    end

    def locate(user)
        token = get_token
        uri = "/restapi/user-locate?name=#{URI.encode_www_form_component user}"

        get(uri, headers: {
            "Accept" => "application/json",
            "Authorization" => token
        }) { |response|
            if (200...300).include?(response.status)
                resp = JSON.parse(response.body, symbolize_names: true)
                # Select users where there is a desk key found
                resp[:info].select { |user| user[:key] }
            else
                expire_token! if response.status == 401
                raise "unexpected response #{response.status}\n#{response.body}"
            end
        }.value
    end

    def fetch_desk_state
        desk_mappings = {}

        @floor_mappings.each do |zone_id, group|
            group_ids = Array(group)
            all_desk_ids = []
            desks_in_use = []
            desks_reserved = []

            # Grab the details for this floor
            group_ids.each do |group_id|
                desks(group_id).each do |details|
                    desk_id = details[:key]
                    controller = details[:cid]
                    occupied = details[:occupied]
                    reserved = details[:reserved]

                    desk_mappings[desk_id] = [zone_id, group_id, controller]
                    all_desk_ids << desk_id
                    desks_in_use << desk_id if occupied
                    desks_reserved << desk_id if reserved && !occupied
                end
            end

            # Make the summaries available to the frontend
            self[zone_id] = desks_in_use
            self["#{zone_id}:reserved"] = desks_reserved
            self["#{zone_id}:desk_ids"] = all_desk_ids

            occupied_count = desks_in_use.size + desks_reserved.size
            self["#{zone_id}:occupied_count"] = occupied_count
            self["#{zone_id}:free_count"] = all_desk_ids.size - occupied_count
            self["#{zone_id}:desk_count"] = all_desk_ids.size
        end

        @desk_mappings = desk_mappings
    rescue => error
        logger.print_error error, 'fetching desk state'
    ensure
        schedule.clear
        schedule.in("5s") { fetch_desk_state }
    end
end
