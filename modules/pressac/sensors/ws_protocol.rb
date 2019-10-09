# encoding: ASCII-8BIT
# frozen_string_literal: true

require 'protocols/websocket'
require 'set'

module Pressac; end
module Pressac::Sensors; end

# Data flow:
# ==========
# Pressac desk / environment / other sensor modules wirelessly connect to 
# Pressac Smart Gateway (https://www.pressac.com/smart-gateway/) uses AMQP or MQTT protocol to push data to MS Azure IOT Hub via internet 
# Local Node-RED docker container (default hostname: node-red) connects to the same Azure IOT hub via AMQP over websocket (using "Azure IoT Hub Receiver" https://flows.nodered.org/node/node-red-contrib-azure-iot-hub)
# Engine module (instance of this driver) connects to Node-RED via websockets. Typically ws://node-red:1880/ws/pressac/

class Pressac::Sensors::WsProtocol
    include ::Orchestrator::Constants

    descriptive_name 'Pressac Sensors via NR websocket'
    generic_name :Sensors
    tcp_port 1880
    wait_response false
    default_settings({
        websocket_path: '/ws/pressac/',
    })

    def on_load
        status = setting(:status) || {}
        self[:desk]       = status[:desk]       || {}   # A hash of all desk names to their sensor values: { desk_name: {data: value, ..}, .. }
        self[:busy_desks] = status[:busy_desks] || []   # Array of desk names
        self[:free_desks] = status[:free_desks] || []
        self[:all_desks]  = status[:all_desks]  || []
        self[:last_update] = status[:last_update]  || "Never"
        self[:environment] = {}                         # Environment sensor values (temp, humidity)
        @busy_desks = self[:busy_desks].to_set
        @free_desks = self[:free_desks].to_set
        
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
        @ws = Protocols::Websocket.new(self, "ws://#{remote_address + @ws_path}")  # Node that id is optional and only required if there are to be multiple endpoints under the /ws/press/
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

        case sensor[:deviceType]
        when 'Under-Desk-Sensor'
            id       = sensor[:deviceName]
            occupied = sensor[:motionDetected] == "true"
            if occupied  
                @busy_desks.add(id)
                @free_desks.delete(id)
            else
                @busy_desks.delete(id)
                @free_desks.add(id)
            end
            self[:busy_desks] = @busy_desks.to_a
            self[:free_desks] = @free_desks.to_a
            self[:all_desks]  = self[:all_desks] | [id]
            self[:desk][id]  = {
                id:      sensor[:deviceId],
                motion:  occupied,
                voltage: sensor[:supplyVoltage][:value],
                gatewayName: sensor[:gatewayName],
                location: sensor[:location],
                timestamp: sensor[:timestamp]
            }
        when 'CO2-Temperature-and-Humidity'
            self[:environment][sensor[:devicename]] = {
                temp:           sensor[:temperature],
                humidity:       sensor[:humidity],
                concentration:  sensor[:concentration],
                dbm:            sensor[:dbm],
                id:             sensor[:deviceid]
            }
        end

        self[:last_update] = Time.now.in_time_zone($TZ).to_s
        # Save the current status to database, so that it can retrieved when engine restarts
        status = {
            busy_desks:  self[:busy_desks],
            free_desks:  self[:free_desks],
            all_desks:   self[:all_desks],
            desk:        self[:desk],
            last_update: self[:last_update]
    }
        define_setting(:status, status)
    end

    # connection is closing
    def on_close(event)
        logger.debug { "Websocket closing... #{event.code} #{event.reason}" }
    end

    def on_error(error)
        logger.warn "Websocket error: #{error.message}"
    end
end