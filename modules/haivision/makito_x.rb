require 'shellwords'
require 'protocols/telnet'

# Documentation: https://aca.im/driver_docs/Haivision/makito_x.pdf

module Haivision; end
class Haivision::MakitoX
    include ::Orchestrator::Constants
    include ::Orchestrator::Transcoder

    # Discovery Information
    descriptive_name 'Haivision Makito X'
    generic_name :Streamer
    tcp_port 23

    # Communication settings
    tokenize delimiter: "\r",
             wait_ready: "login:"
    clear_queue_on_disconnect!

    def on_load
        on_update

        # Allow more ignores
        defaults max_waits: 15

        # Implement the Telnet protocol
        new_telnet_client
        config before_buffering: proc { |data|
            @telnet.buffer data
        }
    end

    def on_update
        @username = setting(:username) || 'admin'
    end

    def connected
        @ignore_responses = true
        do_send @username, wait: false, delay: 200, priority: 98
        do_send setting(:password), wait: false, delay: 200, priority: 97

        schedule.every(100_000) { version }
    end

    def disconnected
        # Ensures the buffer is cleared
        new_telnet_client
    end

    def version
        do_send('haiversion')
    end

    protected

    def received(data, resolve, command)
        # Ignore the command prompt
        return :ignore if data.start_with?(@username)

        logger.debug { "MakitoX sent #{data}" }

        # Ignore login info
        if @ignore_responses
            if command
                @ignore_responses = false
            else
                return :success
            end
        end

        # Grab command data
        key, value = Shellwords.split(data).join('').split(':')
        key = key.underscore
        self[key] = value
        :success
    end

    def new_telnet_client
        @telnet = Protocols::Telnet.new do |data|
            send data, priority: 99, wait: false
        end
    end

    def do_send(command, options = {})
        logger.debug { "requesting #{command}" }
        send @telnet.prepare(command), options
    end
end
