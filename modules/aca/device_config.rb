# frozen_string_literal: true

module Aca; end

class Aca::DeviceConfig
    include ::Orchestrator::Constants

    descriptive_name 'ACA Device Config Manager'
    generic_name :DeviceConfig
    implements :logic
    description <<~DESC
        Utility module for executing device setup actions when connectivity is
        established.

        Actions may be specified under the `device_config` setting. This should
        be of the form:

            mod => { method => args }

        Or, if a method must be executed multiple times

            mod => [{ method => args }]
    DESC

    default_settings(
        # Setup actions to perform on any devices to ensure they are correctly
        # configured for interaction with this system. Structure should be of
        # the form device => { method => args }. These actions will be pushed
        # to the device on connect.
        device_config: {}
    )

    def on_load
        system.load_complete do
            setup_config_subscriptions
        end
    end

    def on_update
        setup_config_subscriptions
    end


    protected


    # Setup event subscriptions to push device setup actions to devices when
    # they connect.
    def setup_config_subscriptions
        @device_config_subscriptions&.each { |ref| unsubscribe ref }

        @device_config_subscriptions = load_config.map do |dev, actions|
            mod, idx = mod_idx_for dev

            system.subscribe(mod, idx, :connected) do |notification|
                next unless notification.value
                logger.debug { "pushing system defined config to #{dev}" }
                device = system.get mod, idx
                actions.each { |(method, args)| device.send method, *args }
           end
       end
    end

    def load_config
        actions = setting(:device_config) || {}

        # Allow device config actions to either be specified as a single hash
        # of method => arg mappings, or an array of these if the same method
        # needs to be called multiple times.
        actions.transform_values! do |exec_methods|
            exec_methods = Array.wrap exec_methods
            exec_methods.flat_map(&:to_a).map do |method, args|
                [method.to_sym, Array.wrap(args)]
            end
        end

        actions.freeze
    end



    # Map a module id in the form name_idx out into its [name, idx] components.
    #
    # @param device [Symbol, String] the module id to destructure
    # @return [[Symbol, Integer]]
    def mod_idx_for(device)
        mod, idx = device.to_s.split '_'
        mod = mod.to_sym
        idx = idx&.to_i || 1
        [mod, idx]
    end
end
