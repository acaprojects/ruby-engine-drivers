module AcaDeviceModules
    class Engine < ::Rails::Engine
        config.after_initialize do |app|
            app.config.orchestrator.module_paths << File.expand_path('../../../modules', __FILE__)
        end
    end
end
