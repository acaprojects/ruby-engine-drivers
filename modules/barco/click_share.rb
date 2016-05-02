module Barco; end

class Barco::ClickShare
    include ::Orchestrator::Constants


    # Discovery Information (service is on port 4000)
    uri_base 'https://clickshare.ip:4000'
    descriptive_name 'ClickShare Wireless Presenter'
    generic_name :WirelessPresenter
    default_settings username: 'integrator', password: 'integrator'

    # Communication settings
    keepalive false
    inactivity_timeout 1500


    def on_load
        on_update
    end
    
    def on_update
        config({
            digest: {
                user:     setting(:username),
                password: setting(:password)
            }
        })
    end

    def room_name(value = nil)
        do_send '/v1.0/OnScreenText/MeetingRoomName', value: value do |resp|
            if resp
                self[:room_name] = resp[:data][:value]
            else
                self[:room_name] = value
            end
        end
    end

    def welcome_message(value = nil)
        do_send '/v1.0/OnScreenText/WelcomeMessage', value: value do |resp|
            if resp
                self[:welcome_message] = resp[:data][:value]
            else
                self[:welcome_message] = value
            end
        end
    end

    # Supports Analog or Digital
    def audio_output(value = nil)
        do_send '/v1.0/Audio/Output', value: value do |resp|
            if resp
                self[:audio_output] = resp[:data][:value]
            else
                self[:audio_output] = value
            end
        end
    end

    def audio_enabled(val = nil)
        value = is_affirmative?(val)
        do_send '/v1.0/Audio/Enabled', value: value do |resp|
            if resp
                self[:audio_enabled] = resp[:data][:value]
            else
                self[:audio_enabled] = value
            end
        end
    end

    def uptime
        do_send '/v1.0/DeviceInfo/CurrentUptime' do |resp|
            self[:uptime] = resp[:data][:value] if resp
        end
    end

    def sharing
        do_send '/v1.0/DeviceInfo/Sharing' do |resp|
            self[:sharing] = resp[:data][:value] if resp
        end
    end

    def status
        do_send '/v1.0/DeviceInfo/StatusMessage' do |resp|
            self[:status] = resp[:data][:value] if resp
        end
    end

    def firmware
        do_send '/v1.0/Software/FirmwareVersion' do |resp|
            self[:firmware] = resp[:data][:value] if resp
        end
    end

    def restart
        do_send '/v1.0/Configuration/RestartSystem', value: true
    end

    def shutdown
        do_send '/v1.0/Configuration/ShutdownSystem', value: true
    end


    protected


    DECODE_OPTIONS = {
        symbolize_names: true
    }.freeze

    def process_response(resp)
        data = nil

        if resp.body && resp.body.length > 0
            data = begin
                ::JSON.parse(resp.body, DECODE_OPTIONS)
            rescue => e
                if resp.body != 'Unauthorized'
                    logger.debug { "error decoding response body: #{resp.body}" }
                end
                nil
            end
        end

        status = data.nil? ? resp.status : (data[:status] || resp.status)

        case status
        when 200
            yield data
            return :success
        when 400
            logger.warn 'Request format is not valid'
        when 403
            logger.warn 'Resource is not writable'
        when 404
            logger.warn 'Resource does not exist'
        when 500
            logger.warn 'Internal server error'
        end

        :abort
    end

    
    def do_send(path, value: nil, options: {})
        if value
            if value.is_a? Hash
                options[:body] = "value=#{value.to_json}"
            else
                options[:body] = "value=#{value}"
            end

            put(path, options) do |resp|
                process_response(resp) do |data|
                    yield data if block_given?
                end
            end
        else
            get(path, options) do |resp|
                process_response(resp) do |data|
                    yield data if block_given?
                end
            end
        end
    end
end
