# frozen_string_literal: true

module Cisco; end
module Cisco::Spark; end
module Cisco::Spark::Xapi; end

# Minimal DSL for mapping Cisco's xAPI to methods.
module Cisco::Spark::Xapi::Mapper
    module ApiMapperMethods
        # Bind an xCommand to a module method.
        #
        # This abuses ruby's ordered hashes and fat arrow hash to provide a
        # neat, declarative syntax for building out Room OS device modules.
        #
        # Example:
        #   command 'Fake n Command' => :my_method,
        #           ParamA: [:enum, :of, :options],
        #           ParamB: String,
        #           OptionalParam_: Integer
        #
        # Will provide the method:
        #   def my_method(index, param_a, param_b, optional_param = nil)
        #       ...
        #   end
        #
        # @param mapping [Hash]
        #  - first k/v pair is a mapping from the xCommand => method_name
        #  - use 'n' within command path elements containing an index element
        #    (as per the device protocol guide), this will be lifted into an
        #    'index' parameter
        #  - all other pairs are ParamName: <type>
        #  - suffix optional params with an underscore
        # @return [Symbol] the mapped method name
        def command(mapping)
            command_path, method_name = mapping.shift

            params = mapping.keys.map { |name| name.to_s.underscore }
            opt_, req = params.partition { |name| name.ends_with? '_' }
            opt = opt_.map { |name| name.chomp '_' }

            param_str = (req + opt.map { |name| "#{name}: nil" }).join ', '

            # TODO: add support for index commands
            command_str = command_path.split(' ').join(' ')

            types = Hash[(req + opt).zip(mapping.values)]
            type_checks = types.map do |param, type|
                case type
                when Class
                    msg = "#{param} must be a #{type}"
                    cond = "#{param}.is_a?(#{type})"
                when Range
                    msg = "#{param} must be within #{type}"
                    cond = "(#{type}).include?(#{param})"
                else
                    msg = "#{param} must be one of #{type}"
                    cond = "#{type}.any? { |t| t.to_s.casecmp(#{param}.to_s) == 0 }"
                end
                "raise ArgumentError, '#{msg}' unless #{param}.nil? || #{cond}"
            end
            type_check_str = type_checks.join "\n"

            class_eval <<~METHOD
                def #{method_name}(#{param_str})
                    #{type_check_str}
                    args = binding.local_variables
                                  .map { |p| [p.to_s.camelize.to_sym, binding.local_variable_get(p)] }
                                  .to_h
                    send_xcommand '#{command_str}', args
                end
            METHOD

            method_name
        end

        # Bind an xCommand to a protected method (admin execution only).
        #
        # @return [Symbol]
        # @see #command
        def command!(mapping)
            protect_method command(mapping)
        end

        # Define a binding between device state and module status variables.
        #
        # Similar to command bindings, this provides a declarative mapping
        # from a device xpath to an exposed status variable. Subscriptions will
        # be automatically setup as part of connection initialisation.
        #
        # Example:
        #   status 'Standby State' => :standby
        #
        # Will track the device standby state and push it to self[:standby]
        #
        # @param mapping [Hash] a set of xpath => status variable bindings
        def status(mapping)
            status_mappings.merge! mapping
        end

        def status_mappings
            @mappings ||= {}
        end
    end

    module ApiMapperHooks
        def connected
            super
            self.class.status_mappings.each(&method(:bind_status))
        end
    end

    module_function

    def included(base)
        base.extend ApiMapperMethods
        base.prepend ApiMapperHooks
    end
end
