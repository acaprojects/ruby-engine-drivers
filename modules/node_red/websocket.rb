# encoding: ASCII-8BIT
# frozen_string_literal: true

require 'protocols/websocket'

module NodeRed; end
module NodeRed::Websocket; end

# Data flow:
# ==========
# Local Node-RED docker container (default hostname: node-red) connects to the same Azure IOT hub via AMQP over websocket (using "Azure IoT Hub Receiver" https://flows.nodered.org/node/node-red-contrib-azure-iot-hub)
# Engine module (instance of this driver) connects to Node-RED via websockets. Typically "ws://node-red:1880/ws/pressac/"

class NodeRed::Websocket
    include ::Orchestrator::Constants

    descriptive_name 'Node-RED Websocket'
    generic_name :Websocket
    tcp_port 1880
    wait_response false
    default_settings({
        websocket_path: '/ws/',
    })

    def on_load
        on_update
    end

    # Called after dependency reload and settings updates
    def on_update
        @ws_path  = setting('websocket_path')
    end

    def connected
        new_websocket_client
    end

    def disconnected
    end


    protected

    def new_websocket_client
        @ws = Protocols::Websocket.new(self, "ws://#{remote_address + @ws_path}")
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
    end

    def on_message(raw_string)
        logger.debug { "received: #{raw_string}" }
        sensor = JSON.parse(raw_string, symbolize_names: true)
    end

    # connection is closing
    def on_close(event)
        logger.debug { "Websocket closing... #{event.code} #{event.reason}" }
    end

    def on_error(error)
        logger.warn "Websocket error: #{error.message}"
    end
end
