# encoding: ASCII-8BIT
# frozen_string_literal: true

require 'protocols/websocket'

module Atlona; end
module Atlona::OmniStream; end

class Atlona::OmniStream::WsProtocol
    include ::Orchestrator::Constants
    include ::Orchestrator::Transcoder
    include ::Orchestrator::Security

    # supports encoders and decoders
    descriptive_name 'Atlona Omnistream WS Protocol'
    # Probably a good idea to differentiate them for support purposes
    generic_name :Decoder

    tcp_port 80
    wait_response false

    def on_load
        on_update
    end

    # Called after dependency reload and settings updates
    def on_update
        @type = self[:type] = setting(:type) if @type.nil?

        @username = setting(:username) || 'admin'
        @password = setting(:password) || 'Atlona'

        @video_in_default = setting(:video_in_default) || 1
        @audio_in_default = setting(:audio_in_default) || 2

        # We'll pair auth with a query to send a command
        @auth = {
            username: @username,
            password: @password
        }.to_json[0..-2]

        # The output this module is interested in
        @num_outputs = (setting(:num_outputs) || 1).to_i
    end

    def connected
        new_websocket_client
    end

    def disconnected
        # clear the keepalive ping
        schedule.clear
    end

    # Encoder
    # hdmi_input => are the sources connected
    # sessions => 1,2,3,4
    #          => audio + video streams and addresses + ports
    #
    # ip_input => 1,2,3,4,5
    #          => hdmi_output -- select an input + output
    Query = {}
    [
        # common
        :systeminfo, :alarms, :net,

        # encoders
        :hdmi_input, :vc2, :sessions,

        # decoders
        :ip_input, :hdmi_output
    ].each do |cmd|
        # Cache the query strings
        # Remove the leading '{' character
        Query[cmd] = {
            id: cmd,
            config_get: cmd
        }.to_json[1..-1]

        # generate the query functions
        define_method cmd do
            data = "#{@auth},#{Query[cmd]}"
            logger.debug { "requesting: #{data}" }
            @ws.text(data)
        end
    end

    def audio_mute(value = true, output: 1)
        raise 'not supported on encoders' unless @type == :decoder

        output -= 1
        id = 399 + output

        val = self[:outputs][output]
        val[:audio][:mute] = true
        val["$$hashKey"] = "object:#{id}"

        @ws.text({
            id: "hdmi_output",
            username: @username,
            password: @password,
            config_set: {
                name: "hdmi_output",
                config: [val]
            }
        }.to_json)

        val
    end

    def audio_unmute(output: 1)
        mute(false, output: output)
    end

    def mute(value = true, output: 1)
        raise 'not supported on encoders' unless @type == :decoder
        switch(enable: !value, output: output, video_ip: '', video_port: 1, audio_ip: '', audio_port: 1)
    end

    def unmute
        mute(false)
    end

    def switch(output: 1, video_ip: nil, video_port: nil, audio_ip: nil, audio_port: nil, enable: true)
        raise 'not supported on encoders' unless @type == :decoder

        out = output - 1
        val = self[:outputs][out]

        raise "unknown output #{output}" unless val

        # Select the inputs to configure
        inputs = self[:ip_inputs]
        audio_inp = val[:audio][:input]
        video_inp = val[:video][:input]

        # An empty string means no stream is selected and we don't want to switch
        audio_ip = nil unless audio_inp.present?
        video_ip = nil unless video_inp.present?

        base_id = 14
        request = {
            id: "ip_input",
            username: @username,
            password: @password,
            config_set: {
                name: "ip_input"
            }
        }

        # Grab the details of the ip_input that should be updated
        if video_ip && video_port
            number = video_inp[-1].to_i
            id = base_id + number - 1

            inp = inputs[video_inp]
            inp["$$hashKey"] = "object:#{id}"
            inp[:number] = number
            if video_ip.empty?
                inp[:enabled] = enable
            else
                inp[:enabled] = enable
                inp[:multicast][:address] = video_ip
                inp[:multicast][:tempAddress] = ''
                inp[:port] = video_port
            end

            request[:config_set][:config] = [inp]
            logger.debug { "switch video:\n#{request}" }
            @ws.text request.to_json
        end

        if audio_ip && audio_port
            number = audio_inp[-1].to_i
            id = base_id + number - 1

            inp = inputs[audio_inp]
            inp["$$hashKey"] = "object:#{id}"
            inp[:number] = number
            if audio_ip.empty?
                inp[:enabled] = enable
            else
                inp[:enabled] = enable
                inp[:multicast][:address] = audio_ip
                inp[:multicast][:tempAddress] = ''
                inp[:port] = audio_port
            end

            request[:config_set][:config] = [inp]
            logger.debug { "switch audio:\n#{request}" }
            @ws.text request.to_json
        end

        raise 'no video or audio stream config provided' unless request[:config_set][:config]
        true
    end

    def select_input(output: 1, video_input: 1, audio_input: 2)
        raise 'not supported on encoders' unless @type == :decoder

        output -= 1
        id = 399 + output
        val = self[:outputs][output]
        val["$$hashKey"] = "object:#{id}"

        if audio_input
            if audio_input == 0
                val[:audio][:input] = ""
            else
                val[:audio][:input] = "ip_input#{audio_input}"
            end
        end

        if video_input
            if video_input == 0
                val[:video][:input] = ""
            else
                val[:video][:input] = "ip_input#{video_input}"
            end
        end

        @ws.text({
            id: "hdmi_output",
            username: @username,
            password: @password,
            config_set: {
                name: "hdmi_output",
                config: [val]
            }
        }.to_json)

        val
    end

    protected

    def new_websocket_client
        # NOTE:: you must use wss:// when using port 443 (TLS connection)
        protocol = secure_transport? ? 'wss' : 'ws'
        @ws = Protocols::Websocket.new(self, "#{protocol}://#{remote_address}/wsapp/")
        @ws.start
    end

    def received(data, resolve, command)
        @ws.parse(data)
        :success
    rescue => e
        logger.print_error(e, 'parsing websocket data')
        disconnect
        :abort
    end

    # ====================
    # Websocket callbacks:
    # ====================

    # websocket ready
    def on_open
        logger.debug { "Websocket connected" }

        schedule.every('30s', :immediately) do
            systeminfo
            alarms
            net
        end
    end

    def on_message(raw_string)
        logger.debug { "received: #{raw_string}" }
        resp = JSON.parse(raw_string, symbolize_names: true)

        # Warn if there was an error
        if resp[:error]
            logger.warn raw_string
            return
        end

        data = resp[:config]

        # if config was successfully updated then query the status
        if data.nil?
            id = resp[:id].to_sym
            self.__send__(id) if self.respond_to?(id)
            return
        end

        # get
        case resp[:id]
        when 'systeminfo'
            # type == :decoder or :encoder
            @type = self[:type] = data[:type].downcase.to_sym

            self[:temperature] = data[:temperature]
            self[:model] = data[:model]
            self[:firmware] = data[:firmwareversion]
            self[:uptime] = data[:uptime]

            if @type == :decoder
                ip_input
                hdmi_output
            else
                hdmi_input
                vc2
                sessions
            end

        when 'net'
            self[:mac_address] = data[0][:macaddress]
        when 'alarms'
            self[:alarms] = data
        when 'hdmi_input'
            self[:inputs] = data
        when 'vc2'
            self[:encoders] = data
        when 'sessions'
            sessions = []
            num_sessions = 0
            data.each do |sess|
                next unless sess[:audio][:stream][:enabled] || sess[:video][:stream][:enabled]
                sessions << sess
                num_sessions += 1
            end
            self[:sessions] = sessions
            self[:num_sessions] = num_sessions
        when 'ip_input'
            ins = {}
            data.each do |input|
                ins[input[:name]] = input
            end
            self[:ip_inputs] = ins
        when 'hdmi_output'
            self[:outputs] = data
            self[:num_outputs] = data.length
        end
    end

    # connection is closing
    def on_close(event)
        logger.debug { "Websocket closing... #{event.code} #{event.reason}" }
    end

    # connection is closing
    def on_error(error)
        logger.warn "Websocket error: #{error.message}"
    end
end
