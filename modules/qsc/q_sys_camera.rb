# encoding: ASCII-8BIT
# frozen_string_literal: true

module Qsc; end

class Qsc::QSysCamera
    include ::Orchestrator::Constants

    # Discovery Information
    implements :logic
    descriptive_name 'QSC PTZ Camera Proxy'
    generic_name :Camera

    def on_load
        on_update
    end

    def on_update
        @mod_id = setting(:driver) || :Mixer
        @ids = setting(:ids)
        self[:no_discrete_zoom] = true
    end

    def power(state)
        state = is_affirmative?(state)
        camera.mute(@ids[:power], state)
    end

    def adjust_tilt(direction)
        direction = direction.to_sym

        case direction
        when :down
            camera.mute(@ids[:tilt_down], true)
        when :up
            camera.mute(@ids[:tilt_up], true)
        else # stop
            camera.mute(@ids[:tilt_up], false)
            camera.mute(@ids[:tilt_down], false)
        end
    end

    def adjust_pan(direction)
        direction = direction.to_sym

        case direction
        when :right
            camera.mute(@ids[:pan_right], true)
        when :left
            camera.mute(@ids[:pan_left], true)
        else # stop
            camera.mute(@ids[:pan_right], false)
            camera.mute(@ids[:pan_left], false)
        end
    end

    def home
        camera.trigger(@ids[:preset_home_load])
    end

    def preset(presetName)
        home
    end

    def zoom(direction)
      direction = direction.to_sym
      case direction
      when :in
        camera.mute(@ids[:zoom_in], true)
      when :out
        camera.mute(@ids[:zoom_out], true)
      else #stop
        camera.mute(@ids[:zoom_in], false)
        camera.mute(@ids[:zoom_out], false)
      end
    end

    protected

    def camera
        system[@mod_id]
    end
end
