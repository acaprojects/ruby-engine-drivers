# frozen_string_literal: true

module Aca::Rooms::Components::Power
    setting powerup_actions: {}

    setting shutdown_actions: {}

    def powerup
        logger.debug 'in power mod'
        :online
    end

    def shutdown
        :shutdown
    end
end
