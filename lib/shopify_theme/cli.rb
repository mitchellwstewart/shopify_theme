require 'thor'
require 'yaml'
YAML::ENGINE.yamler = 'syck' if defined? Syck
require 'abbrev'
require 'base64'
require 'fileutils'
require 'json'
require 'filewatcher'
require 'launchy'
require 'mimemagic'

module ShopifyTheme
  EXTENSIONS = [
    {mimetype: 'application/x-liquid', extensions: %w(liquid), parents: 'text/plain'},
    {mimetype: 'application/json', extensions: %w(json), parents: 'text/plain'},
    {mimetype: 'application/js', extensions: %w(map), parents: 'text/plain'},
    {mimetype: 'application/vnd.ms-fontobject', extensions: %w(eot)},
    {mimetype: 'image/svg+xml', extensions: %w(svg svgz)},
    {mimetype: 'text/css', extensions: %w(scss css), parents: 'text/plain'},
    {mimetype: 'application/font-woff2', extensions: %w(woff2)}
  ]

  def self.configureMimeMagic
    ShopifyTheme::EXTENSIONS.each do |extension|
      MimeMagic.add(extension.delete(:mimetype), extension)
    end
  end

  class Cli < Thor
    include Thor::Actions

    IGNORE = %w(config.yml)
    DEFAULT_WHITELIST = %w(layout/ assets/ config/ snippets/ templates/ locales/)
    TIMEFORMAT = "%H:%M:%S"

    tasks.keys.abbrev.each do |shortcut, command|
      map shortcut => command.to_sym
    end

    desc "check", "check configuration"
    def check
      if ShopifyTheme.check_config
        say("Configuration [OK]", :green)
      else
        say("Configuration [FAIL]", :red)
      end
    end

    desc "configure API_KEY PASSWORD STORE THEME_ID", "generate a config file for the store to connect to"
    def configure(api_key=nil, password=nil, store=nil, theme_id=nil)
      config = {:api_key => api_key, :password => password, :store => store, :theme_id => theme_id}
      create_file('config.yml', config.to_yaml)
    end

    desc "bootstrap API_KEY PASSWORD STORE THEME_NAME", "bootstrap with Timber to shop and configure local directory."
    method_option :master, :type => :boolean, :default => false
    method_option :version, :type => :string, :default => "latest"
    def bootstrap(api_key=nil, password=nil, store=nil, theme_name=nil)
      ShopifyTheme.config = {:api_key => api_key, :password => password, :store => store}

      theme_name ||= 'Timber'
      say("Registering #{theme_name} theme on #{store}", :green)
      theme = ShopifyTheme.upload_timber(theme_name, options[:version])

      say("Creating directory named #{theme_name}", :green)
      empty_directory(theme_name)

      say("Saving configuration to #{theme_name}", :green)
      ShopifyTheme.config.merge!(theme_id: theme['id'])
      create_file("#{theme_name}/config.yml", ShopifyTheme.config.to_yaml)

      say("Downloading #{theme_name} assets from Shopify")
      Dir.chdir(theme_name)
      download()
    rescue Releases::VersionError => e
      say(e.message, :red)
    end

    desc "download FILE", "download the shops current theme assets"
    method_option :quiet, :type => :boolean, :default => false
    method_option :exclude
    def download(*keys)
      if keys.empty?
        asset_list = ShopifyTheme.asset_list
        assets = ShopifyTheme.asset_keys(asset_list)
      else
        assets = keys
      end

      if options['exclude']
        assets = assets.delete_if { |asset| asset =~ Regexp.new(options['exclude']) }
      end

      assets.each do |asset|
        download_asset(asset)
        say("#{ShopifyTheme.api_usage} Downloaded: #{asset}", :green) unless options['quiet']
      end

      ShopifyTheme.save_sync_list(asset_list) if asset_list

      say("Done.", :green) unless options['quiet']
    end

    desc "import", "download the shops changed theme assets"
    method_option :quiet, :type => :boolean, :default => false
    def import
      asset_list = ShopifyTheme.asset_list
      changed_hash = changes(asset_list)

      assets = (changed_hash[:changed].map(&:first) + changed_hash[:created]).flatten
      assets.each do |asset|
        download_asset(asset["key"])
        say("#{ShopifyTheme.api_usage} Downloaded: #{asset['key']}", :green) unless options['quiet']
      end

      changed_hash[:deleted].each do |deleted|
        filename = File.join("theme", deleted['key'])
        if File.exists?(filename)
          File.delete(filename)
          say("Deleted: #{deleted['key']}", :red) unless options['quiet']
        end
      end

      ShopifyTheme.save_sync_list(asset_list)

      say("Done.", :green) unless options['quiet']
    end

    desc "init", "Setup the sync.json and manifest.json"
    method_option :quiet, :type => :boolean, :default => false
    def init
      asset_list = ShopifyTheme.asset_list
      assets = ShopifyTheme.asset_keys(asset_list)
      if options['exclude']
        assets = assets.delete_if { |asset| asset =~ Regexp.new(options['exclude']) }
      end

      assets.each do |asset|
        say("#{ShopifyTheme.api_usage} Initializing: #{asset}", :green) unless options['quiet']
        init_asset(asset)
      end

      ShopifyTheme.save_sync_list(asset_list)
      say("Done.", :green) unless options['quiet']
    end

    desc "export", "upload changes to local theme assets and delete removed files"
    method_option :quiet, :type => :boolean, :default => false
    method_option "dry-run".to_sym, :type => :boolean, :default => false
    def export
      asset_list = ShopifyTheme.asset_list
      changed_hash = changes(asset_list, true)

      if !(changed_hash[:created].empty? && changed_hash[:deleted].empty? && changed_hash[:changed].empty?)
        say("There are remote changes which have not been imported locally", :red)
        exit 1
      end

      keys = ShopifyTheme.asset_keys(asset_list)
      local_keys = local_assets_list

      # Only delete files on remote that are not present locally
      (keys - local_keys).each do |key|
        delete_asset(key, options['quiet'], options['dry-run']) unless ShopifyTheme.ignore_files.any? { |regex| regex =~ key }
      end

      cached_manifest = ShopifyTheme.read_manifest

      # Files present on remote and present locally that have changed get overridden
      local_keys.each do |asset|
        send_asset(asset, options['quiet'], options['dry-run'], cached_manifest)
      end

      # Grab a new copy of the asset list and save it as the current sync file
      ShopifyTheme.save_sync_list(ShopifyTheme.asset_list)

      say("Done.", :green) unless options['quiet']
    end


    desc "changes", "Check the changes for the shops current theme assets"
    method_option :quiet, :type => :boolean, :default => false
    def changes(asset_list=nil, quiet=false)
      json = ShopifyTheme.read_sync_list
      prev_assets = JSON.parse(json) if json
      prev_assets ||= []

      new_assets = asset_list
      new_assets ||= ShopifyTheme.asset_list

      new_hash = {}
      new_assets.each {|new_asset| new_hash[new_asset["key"]] = new_asset }

      prev_hash = {}
      prev_assets.each {|prev_asset| prev_hash[prev_asset["key"]] = prev_asset }

      changed_assets = []
      deleted_assets = []
      prev_assets.each do |prev_asset|
        if new_asset = new_hash[prev_asset["key"]]
          tmp_new_asset = new_asset.dup
          tmp_new_asset.delete("public_url")
          tmp_prev_asset = prev_asset.dup
          tmp_prev_asset.delete("public_url")
          changed_assets << [prev_asset, new_asset] if tmp_prev_asset != tmp_new_asset
        else
          deleted_assets << prev_asset
        end
      end

      created_assets = []
      new_assets.each do |new_asset|
        unless prev_hash[new_asset["key"]]
          created_assets << new_asset
        end
      end

      changes = {
        changed: changed_assets,
        deleted: deleted_assets,
        created: created_assets
      }

      unless options['quiet'] || quiet
        say("\nChanged:\n\n") unless changes[:changed].empty?
        changes[:changed].each do |changed|
          say("  #{changed.first['key']}", :yellow)
        end

        say("\nCreated:\n\n") unless changes[:created].empty?
        changes[:created].each do |created|
          say("  #{created['key']}", :green)
        end

        say("\nDeleted:\n\n") unless changes[:deleted].empty?
        changes[:deleted].each do |deleted|
          say("  #{deleted['key']}", :red)
        end

        if changes[:changed].empty? && changes[:created].empty? && changes[:deleted].empty?
          say("\nNo changes.", :green)
        end
      end

      changes
    end

    desc "open", "open the store in your browser"
    def open(*keys)
      if Launchy.open shop_theme_url
        say("Done.", :green)
      end
    end

    desc "upload FILE", "upload all theme assets to shop"
    method_option :quiet, :type => :boolean, :default => false
    def upload(*keys)
      assets = keys.empty? ? local_assets_list : keys
      assets.each do |asset|
        send_asset(asset, options['quiet'])
      end
      say("Done.", :green) unless options['quiet']
    end

    desc "replace FILE", "completely replace shop theme assets with local theme assets"
    method_option :quiet, :type => :boolean, :default => false
    def replace(*keys)
      say("Are you sure you want to completely replace your shop theme assets? This is not undoable.", :yellow)
      if ask("Continue? (Y/N): ") == "Y"
        # only delete files on remote that are not present locally
        # files present on remote and present locally get overridden anyway
        remote_assets = keys.empty? ? (ShopifyTheme.asset_keys - local_assets_list) : keys
        remote_assets.each do |asset|
          delete_asset(asset, options['quiet']) unless ShopifyTheme.ignore_files.any? { |regex| regex =~ asset }
        end
        local_assets = keys.empty? ? local_assets_list : keys
        local_assets.each do |asset|
          send_asset(asset, options['quiet'])
        end
        say("Done.", :green) unless options['quiet']
      end
    end

    desc "remove FILE", "remove theme asset"
    method_option :quiet, :type => :boolean, :default => false
    def remove(*keys)
      keys.each do |key|
        delete_asset(key, options['quiet'])
      end
      say("Done.", :green) unless options['quiet']
    end

    desc "watch", "upload and delete individual theme assets as they change, use the --keep_files flag to disable remote file deletion"
    method_option :quiet, :type => :boolean, :default => false
    method_option :keep_files, :type => :boolean, :default => false
    def watch
      say("Watching current folder: #{Dir.pwd}", :blue)
      cached_local_assets_list = local_assets_list.dup
      current_branch = branch


      watcher do |filename, event|
        if branch != current_branch
          say("The repository branch has changed", :red)
          exit 1
        end

        filename = filename.gsub("#{Dir.pwd}/theme/", '')

        if event == :delete
          next unless cached_local_assets_list.include?(filename) || filename.match(/^(assets|snippets|templates|config|layout|locales)\//)
        else
          next unless local_assets_list.include?(filename)
        end

        asset_list = ShopifyTheme.asset_list
        changed_hash = changes(asset_list, true)

        if ENV['UNSAFE'].nil?
          if !(changed_hash[:created].empty? && changed_hash[:deleted].empty? && changed_hash[:changed].empty?)
            say("There are remote changes which have not been imported locally", :red)
            exit 1
          end
        end

        action = if [:changed, :new].include?(event)
          :send_asset
        elsif event == :delete
          :delete_asset
        else
          raise NotImplementedError, "Unknown event -- #{event} -- #{filename}"
        end

        send(action, filename, options['quiet'])
        cached_local_assets_list = local_assets_list.dup
        ShopifyTheme.save_sync_list(ShopifyTheme.asset_list)
      end
    end

    desc "systeminfo", "print out system information and actively loaded libraries for aiding in submitting bug reports"
    def systeminfo
      ruby_version = "#{RUBY_VERSION}"
      ruby_version += "-p#{RUBY_PATCHLEVEL}" if RUBY_PATCHLEVEL
      puts "Ruby: v#{ruby_version}"
      puts "Operating System: #{RUBY_PLATFORM}"
      %w(Thor Listen HTTParty Launchy).each do |lib|
        require "#{lib.downcase}/version"
        puts "#{lib}: v" +  Kernel.const_get("#{lib}::VERSION")
      end
    end

    protected

    def branch
      `git rev-parse --abbrev-ref HEAD`.chomp
    end

    def config
      return @config if defined?(@config)

      @config = YAML.load_file('config.yml')[branch]

      if !@config
        say("There is no configuration for the current branch #{branch}", :red)
        exit 1
      end

      @config
    end

    def shop_theme_url
      url = config[:store]
      url += "?preview_theme_id=#{config[:theme_id]}" if config[:theme_id] && config[:theme_id].to_i > 0
      url
    end

    private

    def watcher
      FileWatcher.new(Dir.pwd).watch() do |filename, event|
        yield(filename, event)
      end
    end

    def local_assets_list
      local_files.reject do |p|
        @permitted_files ||= (DEFAULT_WHITELIST | ShopifyTheme.whitelist_files).map{|pattern| Regexp.new(pattern)}
        @permitted_files.none? { |regex| regex =~ p } || ShopifyTheme.ignore_files.any? { |regex| regex =~ p }
      end
    end

    def local_files
      Dir.chdir('theme') do
        Dir.glob(File.join('**', '*')).reject do |f|
          File.directory?(f)
        end
      end
    end

    def init_asset(key)
      return unless valid?(key)
      notify_and_sleep("Approaching limit of API permits. Naptime until more permits become available!") if ShopifyTheme.needs_sleep?
      asset = ShopifyTheme.get_asset(key)
      if asset['value']
        # For CRLF line endings
        content = asset['value'].gsub("\r", "")
      elsif asset['attachment']
        content = Base64.decode64(asset['attachment'])
      end
      digest = Digest::SHA256.hexdigest(content)
      ShopifyTheme.write_key_digest(key, digest)
    end

    def download_asset(key)
      return unless valid?(key)
      notify_and_sleep("Approaching limit of API permits. Naptime until more permits become available!") if ShopifyTheme.needs_sleep?
      asset = ShopifyTheme.get_asset(key)
      if asset['value']
        # For CRLF line endings
        content = asset['value'].gsub("\r", "")
        format = "w"
      elsif asset['attachment']
        content = Base64.decode64(asset['attachment'])
        format = "w+b"
      end
      digest = Digest::SHA256.hexdigest(content)
      ShopifyTheme.write_key_digest(key, digest)

      FileUtils.mkdir_p(File.join('theme', File.dirname(key)))
      File.open(File.join('theme', key), format) {|f| f.write content} if content
    end

    def send_asset(asset, quiet=false, dry_run=false, manifest=nil)
      return unless valid?(asset)
      data = {:key => asset}
      content = File.read(File.join('theme', asset))
      if binary_file?(asset) || ShopifyTheme.is_binary_data?(content)
        content = File.open(File.join('theme', asset), "rb") { |io| io.read }
        data.merge!(:attachment => Base64.encode64(content))
      else
        data.merge!(:value => content)
      end

      digest = Digest::SHA256.hexdigest(content)
      if manifest && manifest[asset] == digest
        #say("[#{timestamp}] Skipped: #{asset}", :yellow) unless quiet
        return
      end

      if dry_run
        say("[#{timestamp}] Uploaded: #{asset}", :green) unless quiet
        return
      end

      response = show_during("[#{timestamp}] Uploading: #{asset}", quiet) do
        ShopifyTheme.send_asset(data)
      end
      if response.success?
        ShopifyTheme.write_key_digest(asset, digest)
        say("[#{timestamp}] Uploaded: #{asset}", :green) unless quiet
      else
        report_error(Time.now, "Could not upload #{asset}", response)
      end
    end

    def delete_asset(key, quiet=false, dry_run=false)
      return unless valid?(key)

      if dry_run
        say("[#{timestamp}] Removed: #{key}", :red) unless quiet
        return
      end

      response = show_during("[#{timestamp}] Removing: #{key}", quiet) do
        ShopifyTheme.delete_asset(key)
      end
      if response.success?
        ShopifyTheme.delete_key_digest(key)
        say("[#{timestamp}] Removed: #{key}", :green) unless quiet
      else
        report_error(Time.now, "Could not remove #{key}", response)
      end
    end

    def notify_and_sleep(message)
      say(message, :red)
      ShopifyTheme.sleep
    end

    def valid?(key)
      return true if DEFAULT_WHITELIST.include?(key.split('/').first + "/")
      say("'#{key}' is not in a valid file for theme uploads", :yellow)
      say("Files need to be in one of the following subdirectories: #{DEFAULT_WHITELIST.join(' ')}", :yellow)
      false
    end

    def binary_file?(path)
      mime = MimeMagic.by_path(path)
      say("'#{path}' is an unknown file-type, uploading asset as binary", :yellow) if mime.nil? && ENV['TEST'] != 'true'
      mime.nil? || !mime.text?
    end

    def report_error(time, message, response)
      say("[#{timestamp(time)}] Error: #{message}", :red)
      say("Error Details: #{errors_from_response(response)}", :yellow)
    end

    def errors_from_response(response)
      object = {status: response.headers['status'], request_id: response.headers['x-request-id']}

      errors = response.parsed_response ? response.parsed_response["errors"] : response.body

      object[:errors] = case errors
                        when NilClass
                          ''
                        when String
                          errors.strip
                        else
                          errors.values.join(", ")
                        end
      object.delete(:errors) if object[:errors].length <= 0
      object
    end

    def show_during(message = '', quiet = false, &block)
      print(message) unless quiet
      result = yield
      print("\r#{' ' * message.length}\r") unless quiet
      result
    end

    def timestamp(time = Time.now)
      time.strftime(TIMEFORMAT)
    end
  end
end
ShopifyTheme.configureMimeMagic
