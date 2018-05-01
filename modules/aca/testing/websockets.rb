require 'protocols/websocket'

module Aca; end
module Aca::Testing; end

class Aca::Testing::Websockets
    include ::Orchestrator::Constants
    include ::Orchestrator::Transcoder

    # wss://echo.websocket.org

    tcp_port 80
    wait_response false

    def connected
        new_websocket_client
    end

    def disconnected
        # clear the keepalive ping
        schedule.clear
    end

    # Send a text message
    def send_text(message)
        @ws.text message
    end

    def close_connection
        @ws.close
    end

    protected

    def new_websocket_client
        @ws = Protocols::Websocket.new(self, "#{setting(:protocol)}#{remote_address}")
        @ws.start
    end

    def received(data, resolve, command)
        @ws.parse(data)
        :success
    end

    # ====================
    # Websocket callbacks:
    # ====================

    # websocket ready
    def on_open
        logger.debug { "Websocket connected" }
        schedule.every('30s') do
            @ws.ping('keepalive')
        end
    end

    def on_message(raw_string)
        # Process request here
        logger.debug { "received: #{raw_string}" }
    end

    def on_ping(payload)
        logger.debug { "received ping: #{payload}" }
    end

    def on_pong(payload)
        logger.debug { "received pong: #{payload}" }
    end

    # connection is closing
    def on_close(event)
        # event.code
        # event.reason
        logger.debug { "closing... #{event.reason} (#{event.code})" }
    end

    # connection is closing
    def on_error(error)
        # error.message
        logger.debug { "ERROR! #{error.message}" }
    end

    # ====================
end
