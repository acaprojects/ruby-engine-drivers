module Lumens; end

# Documentation: https://aca.im/driver_docs/Lumens/DC193-Protocol.pdf
# RS232 controlled device

class Lumens::Dc193
  include ::Orchestrator::Constants
  include ::Orchestrator::Transcoder

  # Discovery Information
  implements :device
  descriptive_name "Lumens DC 193 Document Camera"
  generic_name :Visualiser

  tokenize delimiter: "\xAF", indicator: "\xA0"
  delay between_sends: 100

  def on_load
    self[:zoom_max] = 864
		self[:zoom_min] = 0

    @ready = true
    @power = false
    @zoom_max = 864
    @lamp = false
    @head_led = false
    @frozen = false
    @zoom_range = 0..@zoom_max
  end

  def connected
    schedule.every('50s') { query_status }
    query_status
  end

  def disconnected
    schedule.clear
  end

  def query_status
    # Responses are JSON encoded
    power?.value
    if self[:power]
      lamp?
      zoom?
      frozen?
      max_zoom?
      picture_mode?
    end
  end

  def power(state)
    state = state ? 0x01 : 0x00
    send [0xA0, 0xB0, state, 0x00, 0x00, 0xAF], name: :power
    power?
  end

  def power?
    # item 58 call system status
    send [0xA0, 0xB7, 0x00, 0x00, 0x00, 0xAF], priority: 0
  end

  def lamp(state, head_led = false)
    return if @frozen

    lamps = if state && head_led
              1
            elsif state
              2
            elsif head_led
              3
            else
              0
            end

    send [0xA0, 0xC1, lamps, 0x00, 0x00, 0xAF], name: :lamp
  end

  def lamp?
    send [0xA0, 0x50, 0x00, 0x00, 0x00, 0xAF], priority: 0
  end

  def zoom_to(position, auto_focus = true)
    return if @frozen

    position = (position < 0 ? 0 : @zoom_max) unless @zoom_range.include?(position)
    low = (position & 0xFF)
    high = ((position >> 8) & 0xFF)
    auto_focus = auto_focus ? 0x1F : 0x13
    send [0xA0, auto_focus, low, high, 0x00, 0xAF], name: :zoom_to
  end

  def zoom(direction)
    return if @frozen

    case direction.to_s.downcase
    when "stop"
      send [0xA0, 0x10, 0x00, 0x00, 0x00, 0xAF], name: :stop_zoom
      # Ensures this request is at the normal priority and ordering is preserved
      zoom?(priority: 50)
      # This prevents the auto-focus if someone starts zooming again
      auto_focus(name: :zoom)
    when "in"
      send [0xA0, 0x11, 0x00, 0x00, 0x00, 0xAF], name: :zoom
    when "out"
      send [0xA0, 0x11, 0x01, 0x00, 0x00, 0xAF], name: :zoom
    end
  end

  def zoom_in
    zoom("in")
  end

  def zoom_out
    zoom("out")
  end

  def zoom_stop
    zoom("stop")
  end

  def auto_focus(name = :auto_focus)
    return if @frozen
    send [0xA0, 0xA3, 0x01, 0x00, 0x00, 0xAF], name: name
  end

  def zoom?(priority = 0)
    send [0xA0, 0x60, 0x00, 0x00, 0x00, 0xAF], priority: priority
  end

  def freeze(state)
    state = state ? 1 : 0
    send [0xA0, 0x2C, state, 0x00, 0x00, 0xAF], name: :freeze
  end

  def frozen(state)
    freeze state
  end

  def frozen?
    send [0xA0, 0x78, 0x00, 0x00, 0x00, 0xAF], priority: 0
  end

  def picture_mode(state)
    return if @frozen
    mode = case state.to_s.downcase
           when "photo"
             0x00
           when "text"
             0x01
           when "greyscale", "grayscale"
             0x02
           else
             raise ArgumentError.new("unknown picture mode #{state}")
           end
    send [0xA0, 0xA7, mode, 0x00, 0x00, 0xAF], name: :picture_mode
  end

  def sharp(state)
    picture_mode(state ? "text" : "photo")
  end

  def picture_mode?
    send [0xA0, 0x51, 0x00, 0x00, 0x00, 0xAF], priority: 0
  end

  def max_zoom?
    send [0xA0, 0x8A, 0x00, 0x00, 0x00, 0xAF], priority: 0
  end

  COMMANDS = {
    0xC1 => :lamp,
    0xB0 => :power,
    0xB7 => :power_staus,
    0xA7 => :picture_mode,
    0xA3 => :auto_focus,
    0x8A => :max_zoom,
    0x78 => :frozen_status,
    0x60 => :zoom_staus,
    0x51 => :picture_mode_staus,
    0x50 => :lamp_staus,
    0x2C => :freeze,
    0x1F => :zoom_direct_auto_focus,
    0x13 => :zoom_direct,
    0x11 => :zoom,
    0x10 => :zoom_stop,
  }

  PICTURE_MODES = [:photo, :test, :greyscale]

  def received(data, reesolve, command)
    logger.debug { "DC193 sent: #{byte_to_hex data}" }
    data = str_to_array(data)

    return :abort if (data[3] & 0x01) > 0
    return :retry if (data[3] & 0x02) > 0

    case COMMANDS[data[0]]
    when :power
      data[1] == 0x01
    when :power_staus
      @ready = data[1] == 0x01
      @power = data[2] == 0x01
      logger.debug { "System power: #{@power}, ready: #{@ready}" }
      self[:ready] = @ready
      self[:power] = @power
    when :max_zoom
      @zoom_max = data[1] + (data[2] << 8)
      @zoom_range = 0..@zoom_max
      self[:zoom_range] = {min: 0, max: @zoom_max}
    when :frozen_status, :freeze
      self[:frozen] = @frozen = data[1] == 1
    when :zoom_staus, :zoom_direct_auto_focus, :zoom_direct
      @zoom = data[1].to_i + (data[2] << 8)
      self[:zoom] = @zoom
    when :picture_mode_staus, :picture_mode
      self[:picture_mode] = PICTURE_MODES[data[1]]
    when :lamp_staus, :lamp
      case data[1]
      when 0
        @head_led = @lamp = false
      when 1
        @head_led = @lamp = true
      when 2
        @head_led = false
        @lamp = true
      when 3
        @head_led = true
        @lamp = false
      end
      self[:head_led] = @head_led
      self[:lamp] = @lamp
    when :auto_focus
      # Can ignore this response
    else
      error = "Unknown command #{data[0]}"
      logger.debug { error }
      return :abort
    end

    :success
  end
end
