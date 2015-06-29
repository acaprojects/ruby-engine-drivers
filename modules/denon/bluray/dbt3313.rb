module Denon; end
module Denon::Bluray; end

class Denon::Bluray::Dbt3313
	include ::Orchestrator::Constants
    include ::Orchestrator::Transcoder


    tokenize delimiter: "\x03", indicator: "\x02"
    delay between_sends: 300


	def on_load
		on_update
	end
	
	def on_unload
	end
	
	def on_update
	end
	
	
	def connected
		do_poll
		@polling_timer = schedule.every('1m') do
            do_poll
        end
	end
	
	def disconnected
		@polling_timer.cancel unless @polling_timer.nil?
		@polling_timer = nil
	end

	
	COMMANDS = {
		:power_on	=> ' ',
		:power_off	=> '!',

		:status 	=> '0',

		# Playback
		:play		=> '@',
		:stop		=> 'A',
		:pause		=> 'B',
		:skip		=> 'C',
		:slow		=> 'D',
		:eject		=> 'a',	

		# Menu navigation
		:setup		=> 'E',
		:top_menu	=> 'F',
		:menu		=> 'G',
		:return		=> 'H',
		:audio		=> 'I',
		:subtitle	=> 'J',
		:angle		=> 'K',
		:home		=> 'P',
		:enter		=> 'N'
	}
	CMD_LOOKUP = COMMANDS.invert

	#
	# Automatically creates a callable function for each command
	#	http://blog.jayfields.com/2007/10/ruby-defining-class-methods.html
	#	http://blog.jayfields.com/2008/02/ruby-dynamically-define-method.html
	#
	COMMANDS.each_key do |command|
		define_method command do |*args|
			options = args[0] || {}
			do_send(COMMANDS[command], options)
		end
	end


	def power(state, options = {})
		state = is_affirmative?(state)
		options.merge!({
			delay: 5500   # Delay at least 5 seconds according to manual
		})
		if state == On
			do_send(COMMANDS[:power_on], options)
		else
			do_send(COMMANDS[:power_off], options)
		end
	end


	DIRECTIONS = {
		left: '1',
		up: '2',
		right: '3',
		down: '4'
	}
	def cursor(direction, options = {})
		val = DIRECTIONS[direction.to_sym]
		do_send("M#{val}", options)
	end


	protected

		
	def do_send(cmd, options = {})
		cmd = "\x02#{cmd.ljust(6, "\x00")}\x03"
		gen_bcc(cmd)
		cmd << 0x03
		send(cmd.encode("ASCII-8BIT"), options)
	end

	def gen_bcc(cmd)
		bcc = 0
		cmd[1..-1].each_byte do |byte|
			bcc += byte
		end
		bcc = bcc & 0xff
		cmd << byte_to_hex([bcc])
	end


	def do_poll
		status(:priority => 0) 
	end


	STATUS_CODES = {
		'0'	=> :standby,
		'1'	=> :disc_loading,
		'3'	=> :tray_open,
		'4'	=> :tray_close,
		'A'	=> :no_disc,
		'B'	=> :stop,
		'C'	=> :play,
		'D'	=> :pause,
		'E'	=> :scan_play,
		'F'	=> :slow_scan,
		'G'	=> :setup_mode,
		'I'	=> :resume_stop,
		'J' => :menu,
		'K'	=> :home_menu
	}

	# Example status response:  Bluray_1: 0 66>;;00100000001000000 
	def received(data, resolve, command)	
		logger.debug "Denon Bluray sent ASCII:#{data}"
		
		# Check for invalid command
		return :abort if data[1] == '0'

		# Command was valid
		case CMD_LOOKUP[data[0]]
		when :power_on
			self[:power] = true
			self[:model] = data[2..15]
		when :power_off
			self[:power] = false
		when :play
			self[:playing] = true
			self[:paused] = false
		when :stop
			self[:playing] = false
			self[:paused] = false
		when :pause
			self[:playing] = true
			self[:paused] = true
		when :eject
			self[:ejected] = !self[:ejected]
		when :status
			case STATUS_CODES[data[8]]
			when :standby
				self[:power] = false
				self[:playing] = false
				self[:paused] = false
				self[:ejected] = false
				self[:loading] = false
			when :tray_open
				self[:power] = true
				self[:playing] = false
				self[:paused] = false
				self[:ejected] = true
				self[:loading] = false
			when :tray_close
				self[:power] = true
				self[:playing] = false
				self[:paused] = false
				self[:ejected] = true
				self[:loading] = false
			when :disc_loading
				self[:power] = true
				self[:playing] = false
				self[:paused] = false
				self[:ejected] = false
				self[:loading] = true
			when :no_disc
				self[:power] = true
				self[:playing] = false
				self[:paused] = false
				self[:ejected] = false
				self[:loading] = false
			when :play
				self[:power] = true
				self[:playing] = true
				self[:paused] = false
				self[:ejected] = false
				self[:loading] = false
			when :pause
				self[:power] = true
				self[:playing] = true
				self[:paused] = true
				self[:ejected] = false
				self[:loading] = false
			when :stop
				self[:power] = true
				self[:playing] = false
				self[:paused] = false
				self[:ejected] = false
				self[:loading] = false
			end
		end

		return :success
	end
end
