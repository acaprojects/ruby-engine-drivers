# frozen_string_literal: true

require 'set'

module Cisco; end
module Cisco::Spark; end
module Cisco::Spark::Xapi; end

# Pure utility methods for building Cisco xAPI actions.
module Cisco::Spark::Xapi::Action
    ACTION_TYPE ||= Set.new [
        :xConfiguration,
        :xCommand,
        :xStatus,
        :xFeedback,
        :xPreferences
    ]

    FEEDBACK_ACTION ||= Set.new [
        :register,
        :deregister
    ]

    module_function

    # Serialize an xAPI action into transmittable command.
    #
    # @param type [ACTION_TYPE] the type of action to execute
    # @param args [String, Array<String>] the action args
    # @param kwargs [Hash] an optional hash of keyword arguments for the action
    # @return [String]
    def create_action(type, *args, **kwargs)
        unless ACTION_TYPE.include? type
            raise ArgumentError,
                  "Invalid action type. Must be one of #{ACTION_TYPE}."
        end

        kwargs = kwargs.compact.map do |name, value|
            value = "\"#{value}\"" if value.is_a? String
            "#{name}: #{value}"
        end

        [type, args, kwargs].flatten.join ' '
    end

    # Serialize an xCommand into transmittable command.
    #
    # @param path [String, Array<String>] command path
    # @param args [Hash] an optional hash of keyword arguments
    # @return [String]
    def xcommand(path, args)
        create_action :xCommand, path, **args
    end

    # Serialize an xConfiguration action into a transmittable command.
    #
    # @param path [String, Array<String>] the configuration path
    # @param setting [String] the setting key
    # @param value the configuration value to apply
    # @return [String]
    def xconfiguration(path, setting, value)
        create_action :xConfiguration, path, setting => value
    end

    # Serialize an xStatus request into transmittable command.
    #
    # @param path [String, Array<String>] status path
    # @return [String]
    def xstatus(path)
        create_action :xStatus, path
    end

    # Serialize a xFeedback subscription request.
    #
    # @param action [:register, :deregister]
    # @param path [String, Array<String>] the feedback document path
    # @return [String]
    def xfeedback(action, path)
        unless FEEDBACK_ACTION.include? action
            raise ArgumentError,
                  "Invalid feedback action. Must be one of #{FEEDBACK_ACTION}."
        end

        xpath = tokenize path if path.is_a? String

        create_action :xFeedback, action, "/#{xpath.join '/'}"
    end

    def tokenize(path)
        # Allow space or slash seperated paths
        path.split(/[\s\/\\]/).reject(&:empty?)
    end
end
