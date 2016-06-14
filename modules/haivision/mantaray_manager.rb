
module Haivision; end
class Haivision::MantarayManager
    include ::Orchestrator::Constants


    # Discovery Information
    uri_base 'http://server.address'
    descriptive_name 'Haivision IPTV Mantaray Manager'
    generic_name :IPTV
    default_settings({
        username: 'user',
        password: 'pass',
        channels: {
            one: '324235345',
            two: '343553455'
        }
    })
    description "Channel and box IDs can be discovered at http://server.address/mantaraymanager/devices"

    # Communication settings
    keepalive false
    inactivity_timeout 1500


    def on_load
        on_update
    end

    def on_update
        @username = setting(:username) || ''
        @password = setting(:password) || ''

        @channels = setting(:channels) || {}
        @channels.merge!(@channels.invert)
    end

    def connected
        login
    end

    def login
        post("/login.php?action=/", body: {
            do: 'portal_login',
            username: @username,
            password: @password
        }) do
            # no way to tell if login was successful until we perform a request
            :success
        end
    end

    def query_box(box_id)
        get("/api/devices/#{box_id}", name: "#{box_id}_#{info}") do |resp|
            result, data = process_response(resp)
            if result == :success
                self[:"#{box_id}_power"] = !data[:standbyMode]
                self[:"#{box_id}_volume"] = (data[:volume] * 100).to_i
                self[:"#{box_id}_channel_name"] = data[:channelName]
                self[:"#{box_id}_channel"] = data[:channel]
            end
            result
        end
    end


    def power(state, box_id)
        result = is_affirmative?(state)
        req = result ? 'standby-off' : 'standby-on'
        send_cmd(:power, {
            command: req
        }, box_id) do
            self[:"#{box_id}_power"] = result
            query_box(box_id) if result
        end
    end

    def channel(chan_id, box_id)
        chan = @channels[chan_id.to_sym] || chan_id.to_s

        send_cmd(:channel, {
            command: 'set-channel',
            parameters: { channelId: chan }
        }, box_id) do
            self[:"#{box_id}_channel"] = chan
            query_box(box_id)
        end
    end

    def volume(val, box_id)
        vol = in_range(val.to_i, 100).to_f / 100

        send_cmd(:volume, {
            command: 'set-volume',
            parameters: { volume: vol }
        }, box_id) do
            self[:"#{box_id}_volume"] = val.to_i
        end
    end

    def mute(state, box_id)
        result = is_affirmative?(state)
        req = result ? 'mute' : 'unmute'
        send_cmd :mute, {command: req}, box_id do
            self[:"#{box_id}_mute"] = result
        end
    end


    protected


    # JSON decode options
    DECODE_OPTIONS = {
        symbolize_names: true
    }.freeze

    def process_response(data)
        if [201, 200].include? data.status
            begin
                resp = ::JSON.parse(data.body, DECODE_OPTIONS)[:data]
                [:success, resp]
            rescue => e
                logger.print_error e, 'parsing response'
                [:abort, nil]
            end
        elsif data.status == 401
            login
            [:retry, nil]
        else
            [:abort, nil]
        end
    end

    def send_cmd(name, data, box_id)
        message = data.to_json
        logger.debug { "Requesting #{message}" }
        post("/api/devices/#{box_id}/commands", body: message, headers: {
            'content-type' => 'application/json'
        }, name: "#{box_id}_#{name}") do |resp|
            result, data = process_response(resp)
            yield data if result == :success && block_given?
            result
        end
    end
end
