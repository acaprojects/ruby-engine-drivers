# frozen_string_literal: true

require 'json'
require 'securerandom'

Dir[File.join(__dir__, '{xapi,util}', '*.rb')].each { |lib| load lib }

module Cisco; end
module Cisco::CollaborationEndpoint; end

class Cisco::CollaborationEndpoint::RoomOs
    include ::Orchestrator::Constants
    include ::Orchestrator::Security
    include ::Cisco::CollaborationEndpoint::Xapi
    include ::Cisco::CollaborationEndpoint::Util

    implements :ssh
    descriptive_name 'Cisco Collaboration Endpoint'
    generic_name :VidConf

    description <<~DESC
        Low level driver for any Cisco Room OS device. This may be used
        if direct access is required to the device API, or a required feature
        is not provided by the device specific implementation.

        Where possible use the implementation for room device in use
        (i.e. SX80, Room Kit etc).
    DESC

    tokenize delimiter: Tokens::COMMAND_RESPONSE,
             wait_ready: Tokens::LOGIN_COMPLETE
    clear_queue_on_disconnect!


    # ------------------------------
    # Callbacks

    def on_load
        load_settings
    end

    def on_unload; end

    def on_update
        load_settings

        # Force a reconnect and event resubscribe following module updates.
        disconnect
    end

    def connected
        init_connection

        register_control_system.then do
            schedule.every('30s') { heartbeat timeout: 35 }
        end

        push_config

        sync_config
    end

    def disconnected
        clear_device_subscriptions

        schedule.clear
    end

    # Handle all incoming data from the device.
    #
    # In addition to acting an the normal Orchestrator callback, on_receive
    # procs also pipe through here for initial JSON decoding. See #do_send.
    def received(data, deferrable, command)
        logger.debug { "<- #{data}" }

        do_parse = proc { Response.parse data }
        response = data.length > 1024 ? task(&do_parse).value : do_parse.call

        if block_given?
            # Let any pending command response handlers have first pass...
            yield(response).tap do |command_result|
                # Otherwise support interleaved async events
                unhandled = [:ignore, nil].include? command_result
                device_subscriptions.notify response if unhandled
            end
        else
            device_subscriptions.notify response
            :ignore
        end
    rescue Response::ParserError => error
        case data.strip
        when 'OK'
            :success
        when 'Command not recognized.'
            logger.error { "Command not recognized: `#{command[:data]}`" }
            :abort
        else
            logger.warn { "Malformed device response: #{error}" }
            :fail
        end
    end


    # ------------------------------
    # Exec methods

    # Execute an xCommand on the device.
    #
    # @param command [String] the command to execute
    # @param multiline_body [String] an optional multiline body for the command
    # @param kwargs [Hash] the command arguments
    # @return [::Libuv::Q::Promise] resolves when the command completes
    def xcommand(command, multiline_body = nil, **kwargs)
        send_xcommand command, multiline_body, kwargs
    end

    # Push a configuration settings to the device.
    #
    # May be specified as either a deeply nested hash of settings, or a
    # pre-concatenated path along with a subhash for drilling through deeper
    # parts of the tree.
    #
    # @param path [Hash, String] the configuration or top level path
    # @param settings [Hash] the configuration values to apply
    # @param [::Libuv::Q::Promise] resolves when the commands complete
    def xconfiguration(path, settings = nil)
        if settings.nil?
            send_xconfigurations path
        else
            send_xconfigurations path => settings
        end
    end

    # Trigger a status update for the specified path.
    #
    # @param path [String] the status path
    # @param [::Libuv::Q::Promise] resolves with the status response as a Hash
    def xstatus(path)
        send_xstatus path
    end

    def self.extended(child)
        child.class_eval do
            protect_method :xcommand, :xconfigruation, :xstatus
        end
    end


    # ------------------------------
    # External feedback subscriptions

    # Subscribe another module to async device events.
    #
    # Callback methods must be of arity 1 and public.
    #
    # @param path [String] the event path
    # @param mod_id [Symbol] the module id containing the callback
    # @param cb [Symbol] the callback method
    def on_event(path, mod_id, cb)
        logger.debug { "Registering callback for #{path} to #{mod_id}.#{cb}" }

        register_feedback path do |event|
            logger.debug { "Proxying #{path} event to #{mod_id}.#{cb}" }

            reactor = ::Libuv::Reactor.current
            # FIXME: switch to ModuleLoader.instance.get when available
            mod     = ::Orchestrator::Control.instance.loaded? mod_id
            proxy   = ::Orchestrator::Core::RequestProxy.new reactor, mod

            proxy.send cb, event
        end
    end

    # Clear external event subscribtions for a specific device path.
    #
    # @param path [String] the event path
    def clear_event(path)
        logger.debug { "Clearing event subscription for #{path}" }

        unregister_feedback path
    end

    protect_method :on_event, :clear_event


    protected


    # ------------------------------
    # xAPI interactions

    # Perform the actual command execution - this allows device implementations
    # to protect access to #xcommand and still refer the gruntwork here.
    #
    # @param comand [String] the xAPI command to execute
    # @param multiline_body [String] an optional multiline body for the command
    # @param kwargs [Hash] the command keyword args
    # @return [::Libuv::Q::Promise] that will resolve when execution is complete
    def send_xcommand(command, multiline_body = nil, **kwargs)
        request = Action.xcommand command, kwargs

        # Multi-arg commands (external source registration, UI interaction etc)
        # all need to be properly queued and sent without be overriden. In
        # these cases, leave the outgoing commands unnamed.
        opts = {}
        opts[:name] = command if kwargs.empty?
        opts[:name] = "#{command} #{kwargs.keys.first}" if kwargs.size == 1

        do_send request, multiline_body, **opts do |response|
            # The result keys are a little odd: they're a concatenation of the
            # last two command elements and 'Result', unless the command
            # failed in which case it's just 'Result'.
            # For example:
            #   xCommand Video Input SetMainVideoSource ...
            # becomes:
            #   InputSetMainVideoSourceResult
            result_key = command.split(' ').last(2).join('') + 'Result'
            command_result = response.dig :CommandResponse, result_key.to_sym
            failure_result = response.dig :CommandResponse, :Result

            result = command_result || failure_result

            if result
                if result[:status] == 'OK'
                    result
                else
                    logger.error result[:Reason]
                    :abort
                end
            else
                logger.warn 'Unexpected response format'
                :abort
            end
        end
    end

    # Apply a single configuration on the device.
    #
    # @param path [String] the configuration path
    # @param setting [String] the configuration parameter
    # @param value [#to_s] the configuration value
    # @return [::Libuv::Q::Promise]
    def send_xconfiguration(path, setting, value)
        request = Action.xconfiguration path, setting, value

        do_send request, name: "#{path} #{setting}" do |response|
            result = response.dig :CommandResponse, :Configuration

            if result&.[](:status) == 'Error'
                logger.error "#{result[:Reason]} (#{result[:XPath]})"
                :abort
            else
                :success
            end
        end
    end

    # Apply a set of configurations.
    #
    # @param config [Hash] a deeply nested hash of the configurations to apply
    # @return [::Libuv::Q::Promise]
    def send_xconfigurations(config)
        # Reduce the config to a strucure of { [path] => value }
        flatten = lambda do |h, path = [], settings = {}|
            return settings.merge!(path => h) unless h.is_a? Hash
            h.each { |key, subtree| flatten[subtree, path + [key], settings] }
            settings
        end
        config = flatten[config]

        # The API only allows a single setting to be applied with each request.
        interactions = config.map do |(*path, setting), value|
            send_xconfiguration path.join(' '), setting, value
        end

        thread.all(*interactions).then { :success }
    end

    # Query the device's current status.
    #
    # @param path [String]
    # @yield [response] a pre-parsed response object for the status query
    # @return [::Libuv::Q:Promise]
    def send_xstatus(path)
        request = Action.xstatus path

        defer = thread.defer

        interaction = do_send request do |response|
            path_components = Action.tokenize path
            status_response = response.dig :Status, *path_components.map(&:to_sym)

            if !status_response.nil?
                defer.resolve status_response
                :success
            else
                error = response.dig :CommandResponse, :Status
                if error
                    logger.error "#{error[:Reason]} (#{error[:XPath]})"
                else
                    logger.error "bad response: #{response[:CommandResponse]}"
                end
                :abort
            end
        end

        interaction.catch { |e| defer.reject e }

        defer.promise
    end


    # ------------------------------
    # Event subscription

    # Subscribe to feedback from the device.
    #
    # @param path [String, Array<String>] the xPath to subscribe to updates for
    # @param update_handler [Proc] a callback to receive updates for the path
    def register_feedback(path, &update_handler)
        logger.debug { "Subscribing to device feedback for #{path}" }

        unless device_subscriptions.contains? path
            request = Action.xfeedback :register, path
            # Always returns an empty response, nothing special to handle
            result = do_send request
        end

        device_subscriptions.insert path, &update_handler

        result || :success
    end

    def unregister_feedback(path)
        logger.debug { "Unsubscribing feedback for #{path}" }

        device_subscriptions.remove path

        request = if path == '/'
                      Action.xfeedback :deregisterall
                  else
                      Action.xfeedback :deregister, path
                  end

        do_send request
    end

    def clear_device_subscriptions
        unregister_feedback '/'
    end

    def device_subscriptions
        @device_subscriptions ||= FeedbackTrie.new
    end


    # ------------------------------
    # Base comms

    def init_connection
        send "Echo off\n", priority: 96 do |response|
            :success if response.include? "\e[?1034h"
        end

        send "xPreferences OutputMode JSON\n", wait: false
    end

    # Execute raw command on the device.
    #
    # @param command [String] the raw command to execute
    # @param multiline_body [String] an optional multiline body for the command
    # @param options [Hash] options for the transport layer
    # @yield [response]
    #   a pre-parsed response object for the command, if used this block
    #   should return the response result
    # @return [::Libuv::Q::Promise]
    def do_send(command, multiline_body = nil, **options)
        request_id = generate_request_uuid

        request = "#{command} | resultId=\"#{request_id}\"\n"

        logger.debug { "-> #{request}" }

        if multiline_body
            # Command header
            send request, wait: false

            # Multiline body
            # Note: somewhere in the comms stack outgoing commands appear to be
            # truncated around 4Kb.
            multiline_body.scan(/.{1,4000}/).each do |chunk|
                send chunk, wait: false
            end

            # Multiline body terminator
            request = "\n.\n"
        end

        send request, **options do |response, defer, cmd|
            received response, defer, cmd do |json|
                if json[:ResultId] != request_id
                    :ignore
                elsif block_given?
                    yield json
                else
                    :success
                end
            end
        end
    end

    def generate_request_uuid
        SecureRandom.uuid
    end


    # ------------------------------
    # Module status

    # Load a setting into a status variable of the same name.
    def load_setting(name, default:, persist: false)
        value = setting(name)
        define_setting(name, default) if value.nil? && persist
        self[name] = value || default
    end

    def load_settings
        load_setting :peripheral_id, default: SecureRandom.uuid, persist: true
    end

    # Bind arbitary device feedback to a status variable.
    def bind_feedback(path, status_key)
        register_feedback path do |value|
            value = self[status_key].deep_merge value \
                if self[status_key].is_a?(Hash) && value.is_a?(Hash)
            self[status_key] = value
        end
    end

    # Bind device status to a module status variable.
    def bind_status(path, status_key)
        bind_feedback "/Status/#{path.tr ' ', '/'}", status_key
        send_xstatus(path).then do |value|
            self[status_key] = value
        end
    end

    def push_config
        config = setting(:device_config) || {}
        send_xconfigurations config
    end

    def sync_config
        bind_feedback '/Configuration', :configuration
        send "xConfiguration *\n", wait: false
    end


    # ------------------------------
    # Connectivity management

    def register_control_system
        send_xcommand 'Peripherals Connect',
                      ID: self[:peripheral_id],
                      Name: 'ACAEngine',
                      Type: :ControlSystem
    end

    def heartbeat(timeout:)
        send_xcommand 'Peripherals HeartBeat',
                      ID: self[:peripheral_id],
                      Timeout: timeout
    end
end
