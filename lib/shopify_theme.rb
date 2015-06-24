require 'httparty'
require 'ap'
module ShopifyTheme
  include HTTParty
  @@current_api_call_count = 0
  @@total_api_calls = 40

  NOOPParser = Proc.new {|data, format| {} }
  TIMER_RESET = 10
  PERMIT_LOWER_LIMIT = 3

  def self.test?
    ENV['test']
  end

  def self.manage_timer(response)
    return unless response.headers['x-shopify-shop-api-call-limit']
    @@current_api_call_count, @@total_api_calls = response.headers['x-shopify-shop-api-call-limit'].split('/')
    @@current_timer = Time.now if @current_timer.nil?
  end

  def self.critical_permits?
    @@total_api_calls.to_i - @@current_api_call_count.to_i < PERMIT_LOWER_LIMIT
  end

  def self.passed_api_refresh?
    delta_seconds > TIMER_RESET
  end

  def self.delta_seconds
    Time.now.to_i - @@current_timer.to_i
  end

  def self.needs_sleep?
    critical_permits? && !passed_api_refresh?
  end

  def self.sleep
    if needs_sleep?
      Kernel.sleep(TIMER_RESET - delta_seconds)
      @current_timer = nil
    end
  end

  def self.api_usage
    "[API Limit: #{@@current_api_call_count || "??"}/#{@@total_api_calls || "??"}]"
  end

  # This is the remote asset list, basically a listing of all of the files
  # in the theme currently uploaded to Shopify
  def self.asset_list
    # HTTParty parser chokes on assest listing, have it noop
    # and then use a rel JSON parser.
    response = shopify.get(path, :parser => NOOPParser)
    manage_timer(response)
    if response.code == 401
      puts JSON.parse(response.body)["errors"]
      exit 1
    end

    assets = JSON.parse(response.body)["assets"]
    keys = assets.map { |a| a['key'] }
    assets.reject{ |a| keys.include?("#{a['key']}.liquid") }
  end

  def self.asset_keys(asset_list=nil)
    keys = (asset_list || self.asset_list).collect {|a| a['key'] }
  end

  # The sync list or sync.json is an unmodified copy of the remote
  # asset list. Basically it is used to quickly diff against the
  # the server so you can know what the last version of the remote assets
  # were. So if you compare the asset_list (remote) to the sync_list (local)
  # you'll know what changed on the remote since you last checked.
  def self.read_sync_list
    return unless File.exists?('sync.json')
    json = File.read('sync.json')
  end

  def self.save_sync_list(assets)
    File.open('sync.json', 'w') {|f| f.write JSON.pretty_generate(assets)}
  end

  def self.get_asset(asset)
    response = shopify.get(path, :query =>{:asset => {:key => asset}}, :parser => NOOPParser)
    manage_timer(response)

    # HTTParty json parsing is broken?
    asset = response.code == 200 ? JSON.parse(response.body)["asset"] : {}
    asset['response'] = response
    asset
  end

  def self.send_asset(data)
    response = shopify.put(path, :body =>{:asset => data})
    manage_timer(response)
    response
  end

  def self.delete_asset(asset)
    response = shopify.delete(path, :body =>{:asset => {:key => asset}})
    manage_timer(response)
    response
  end

  def self.upload_timber(name, version)
    release = Releases.new.find(version)
    response = shopify.post("/admin/themes.json", :body => {:theme => {:name => name, :src => release.zip_url, :role => 'unpublished'}})
    manage_timer(response)
    body = JSON.parse(response.body)
    if theme = body['theme']
      puts "Successfully created #{name} using Shopify Timber #{version}"
      watch_until_processing_complete(theme)
    else
      puts "Could not download theme!"
      puts body
      exit 1
    end
  end


  # The manifest.json is a key=value where the key is the name of the
  # asset and value is a digest of the content. This manifest file is
  # updated (via write_key_digest or delete_key_digest) when (1) a file
  # is downloaded (2) a file is deleted or (3) a file is uploaded
  #
  # The only thing this is used for is to decide what assets that should
  # be uploaded can be skipped (in send_asset)
  #
  def self.read_manifest
    return JSON.parse(File.read('manifest.json')) if File.exists?('manifest.json')

    {}
  end

  def self.write_key_digest(key, digest)
    manifest = read_manifest

    if digest
      manifest[key] = digest
    else
      manifest.delete(key)
    end

    File.open('manifest.json', 'w') {|f| f.write JSON.pretty_generate(manifest)}
    manifest
  end

  def self.delete_key_digest(key)
    write_key_digest(key, nil)
  end

  def self.branch
    `git rev-parse --abbrev-ref HEAD`.chomp
  end

  def self.config
    @config ||= if File.exist? 'config.yml'
      config = YAML.load(File.read('config.yml'))[branch]
      if !config
        puts "There is no configuration for the current branch #{branch} in config.yml"
        exit 1
      end
      config
    else
      puts "config.yml does not exist!" unless test?
      {}
    end
  end

  def self.config=(config)
    @config = config
  end

  def self.path
    @path ||= config[:theme_id] ? "/admin/themes/#{config[:theme_id]}/assets.json" : "/admin/assets.json"
  end

  def self.ignore_files
    (config[:ignore_files] || []).compact.map { |r| Regexp.new(r) }
  end

  def self.whitelist_files
    (config[:whitelist_files] || []).compact
  end

  def self.is_binary_data?(string)
    if string.respond_to?(:encoding)
      string.encoding == "US-ASCII"
    else
      ( string.count( "^ -~", "^\r\n" ).fdiv(string.size) > 0.3 || string.index( "\x00" ) ) unless string.empty?
    end
  end

  def self.check_config
    shopify.get(path).code == 200
  end

  private
  def self.shopify
    basic_auth config[:api_key], config[:password]
    base_uri "https://#{config[:store]}"
    ShopifyTheme
  end

  def self.watch_until_processing_complete(theme)
    count = 0
    while true do
      Kernel.sleep(count)
      response = shopify.get("/admin/themes/#{theme['id']}.json")
      theme = JSON.parse(response.body)['theme']
      return theme if theme['previewable']
      count += 5
    end
  end
end

