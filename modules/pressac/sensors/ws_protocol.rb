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

    descriptive_name 'Pressac Sensors via websocket (local Node-RED)'
    generic_name :Websocket
    tcp_port 1880
    wait_response false
    default_settings({
        websocket_path: '/ws/pressac/',
    })

    def on_load
        @busy_desks = {}
        @free_desks = {}
        status = setting(:status) || {}
        self[:gateways]   = status[:gateways]  || {}
        self[:last_update] = status[:last_update]  || "Never"
        self[:environment] = {}  # Environment sensor values (temp, humidity)
        
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

    def mock(sensor, occupied)
        gateway = which_gateway(sensor)
        self[:gateways][gateway][:busy_desks] = occupied ? self[:gateways][gateway][:busy_desks] | [sensor] : self[:gateways][gateway][:busy_desks] -  [sensor]
        self[:gateways][gateway][:free_desks] = occupied ? self[:gateways][gateway][:free_desks] -  [sensor]  : self[:gateways][gateway][:free_desks] | [sensor]
        self[:gateways][gateway][sensor] = self[gateway] = {
            id:        'mock_data',
            name:      sensor,
            motion:    occupied,
            voltage:   '3.0',
            location:  nil,
            timestamp: Time.now.to_s,
            gateway:   gateway
        }
    end

    def which_gateway(sensor)
        self[:gateways]&.each do |g,sensors|
            return g if sensors.include? sensor
        end
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

        case (sensor[:deviceType] || sensor[:devicetype])
        when 'Under-Desk-Sensor'
            # Variations in captialisation of sensor's key names exist amongst different firmware versions
            sensor_name = sensor[:deviceName].to_sym  || sensor[:devicename].to_sym
            gateway     = sensor[:gatewayName].to_sym || 'unknown_gateway'.to_sym
            occupancy   = sensor[:motionDetected] == true

            @free_desks[gateway]     ||= []
            @busy_desks[gateway]     ||= []
            self[:gateways][gateway] ||= {}
            
            if occupancy
                @busy_desks[gateway] = @busy_desks[gateway] | [sensor_name]
                @free_desks[gateway] = @free_desks[gateway] - [sensor_name]
            else
                @busy_desks[gateway] = @busy_desks[gateway] - [sensor_name]
                @free_desks[gateway] = @free_desks[gateway] | [sensor_name]
            end
            self[:gateways][gateway][:busy_desks] = @busy_desks[gateway]
            self[:gateways][gateway][:free_desks] = @free_desks[gateway]
            self[:gateways][gateway][:all_desks]  = @busy_desks[gateway] + @free_desks[gateway]
            
            # store the new sensor data under the gateway name (self[:gateways][gateway][sensor_name]), 
            # AND as the latest notification from this gateway (self[gateway]) (for the purpose of the DeskManagent logic upstream)
            self[:gateways][gateway][sensor_name] = self[gateway] = {
                id:        sensor[:deviceId] || sensor[:deviceid],
                name:      sensor_name,
                motion:    occupancy,
                voltage:   sensor[:supplyVoltage][:value] || sensor[:supplyVoltage],
                location:  sensor[:location],
                timestamp: sensor[:timestamp],
                gateway:   gateway
            }
            #signal_status(gateway)
            self[:gateways][gateway][:last_update] = sensor[:timestamp]
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
            last_update: self[:last_update],
            gateways:    self[:gateways]
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
