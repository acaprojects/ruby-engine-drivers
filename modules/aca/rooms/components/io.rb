# frozen_string_literal: true

module Aca::Rooms::Components::Io
    setting default_routes: {}

    def show(source, on: default_outputs)
        source = source.to_sym
        target = Array(on).map(&:to_sym)

        logger.debug "Showing #{source} on #{target.join ','}"

        connect source => target
    end

    protected

    def connect(signal_map)
        logger.debug 'called connect'
    end

    def blank(outputs)
        logger.debug 'called blank'
    end

    def default_outputs
        []
    end
end

# Aca::Rooms::Components::Io.extend ::Aca::Rooms::ComponentManager::Composer

Aca::Rooms::Components::Io.compose_with :Power do
    during :powerup do
        connect {} # config.default_routes
    end

    during :shutdown do
        connect {}
    end
end
