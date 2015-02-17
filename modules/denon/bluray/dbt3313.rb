module Denon; end
module Denon::Bluray; end

class Denon::Bluray::Dbt3313
	include ::Orchestrator::Constants
    include ::Orchestrator::Transcoder


	def on_load
		on_update
	end
	
	def on_unload
	end
	
	def on_update
		defaults({
			delay: 300
		})
		config({
			tokenize: true,
			delimiter: "\x03",
			indicator: "\x02",
            encoding: "ASCII-8BIT"
		})
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
		:home		=> 'P'
	}

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
			delay: 5500
		})
		if state == On
			do_send(COMMANDS[:power_on], options)
		else
			do_send(COMMANDS[:power_off], options)
		end
	end



	RESPONSES = {
		0x30	=> :standby,
		0x31	=> :disc_loading,
		0x33	=> :tray_open,
		0x34	=> :tray_close,
		0x41	=> :no_disc,
		0x42	=> :stop,
		0x43	=> :play,
		0x44	=> :pause,
		0x45	=> :scan_play,
		0x46	=> :slow_scan,
		0x47	=> :setup_mode,
		0x49	=> :resume_stop,
		0x4A	=> :menu,
		0x4B	=> :home_menu
	}

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

	# Example power response:  Bluray_1: 0 66>;;00100000001000000 
	def received(data, resolve, command)	
		logger.debug data
		return :success
	end
end
