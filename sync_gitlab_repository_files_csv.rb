#!/usr/bin/env ruby
# frozen_string_literal: true
#
# How to run:
#
#   1. Make sure dependencies are installed, and that a Gemfile exists in the current directory:
#        bundle install
#
#   2. Provide credentials via .env or exported environment variables:
#        export DX_API_TOKEN=...
#        export GITLAB_TOKEN=...
#
#   3. Preview which repositories would be selected without calling GitLab:
#        bundle exec ruby sync_gitlab_repository_files_csv.rb \
#          --dry-run --project-limit 5 --verbose
#
#   4. Run a small real export first:
#        bundle exec ruby sync_gitlab_repository_files_csv.rb \
#          --output-csv tmp/gitlab_repository_files.csv \
#          --project-limit 5 --verbose \
#          --default-instance-url https://gitlab.com/
#
#   5. Run the full export after the limited run looks correct:
#        bundle exec ruby sync_gitlab_repository_files_csv.rb \
#          --output-csv tmp/gitlab_repository_files.csv \
#          --default-instance-url https://gitlab.com/ \
#          --verbose
#
# Useful options:
#   --per-page N          GitLab page size, 1-100. Default: 100.
#   --project-limit N     Limit the number of project rows processed.
#   --dry-run             List repositories only.

require "dotenv/load"
require "csv"
require "fileutils"
require "json"
require "net/http"
require "optparse"
require "uri"

class HttpError < StandardError
  attr_reader :status, :response_body

  def initialize(message, status:, response_body: nil)
    super(message)
    @status = status
    @response_body = response_body
  end
end

class GitlabClient
  RETRYABLE_STATUSES = [429, 500, 502, 503, 504].freeze

  def initialize(token:, user_agent:, open_timeout: 10, read_timeout: 30, max_retries: 4)
    @token = token
    @user_agent = user_agent
    @open_timeout = open_timeout
    @read_timeout = read_timeout
    @max_retries = max_retries
  end

  def fetch_tree_entries(instance_url:, project_source_id:, ref:, per_page:, dry_run: false)
    return enum_for(:fetch_tree_entries, instance_url:, project_source_id:, ref:, per_page:, dry_run:) unless block_given?
    return if dry_run

    encoded_project_id = URI.encode_www_form_component(project_source_id.to_s)
    page = 1

    loop do
      response = get_tree_page(
        instance_url: instance_url,
        encoded_project_id: encoded_project_id,
        ref: ref,
        page: page,
        per_page: per_page
      )

      entries = parse_json(response.body)
      entries.each { |entry| yield entry }

      next_page = response["x-next-page"].to_s.strip
      break if next_page.empty?

      page = next_page.to_i
      break if page <= 0
    end
  end

  def fetch_project_metadata(instance_url:, project_source_id:, dry_run: false)
    return nil if dry_run

    encoded_project_id = URI.encode_www_form_component(project_source_id.to_s)
    uri = build_project_uri(instance_url:, encoded_project_id:)
    response = perform_get(uri)
    payload = parse_json(response.body)
    {
      project_id: Integer(payload.fetch("id")),
      default_branch: payload.fetch("default_branch").to_s.strip
    }
  end

  private

  def build_project_uri(instance_url:, encoded_project_id:)
    api_base = instance_url.end_with?("/") ? "#{instance_url}api/v4/" : "#{instance_url}/api/v4/"
    URI.join(api_base, "projects/#{encoded_project_id}")
  end

  def get_tree_page(instance_url:, encoded_project_id:, ref:, page:, per_page:)
    uri = build_tree_uri(
      instance_url: instance_url,
      encoded_project_id: encoded_project_id,
      ref: ref,
      page: page,
      per_page: per_page
    )

    with_retries(uri) do
      request = Net::HTTP::Get.new(uri)
      request["PRIVATE-TOKEN"] = @token
      request["Accept"] = "application/json"
      request["User-Agent"] = @user_agent

      response = Net::HTTP.start(
        uri.host,
        uri.port,
        use_ssl: uri.scheme == "https",
        open_timeout: @open_timeout,
        read_timeout: @read_timeout
      ) do |http|
        http.request(request)
      end

      unless response.is_a?(Net::HTTPSuccess)
        raise HttpError.new(
          "HTTP #{response.code} returned from #{uri}",
          status: response.code.to_i,
          response_body: response.body
        )
      end

      response
    end
  end

  def build_tree_uri(instance_url:, encoded_project_id:, ref:, page:, per_page:)
    api_base = instance_url.end_with?("/") ? "#{instance_url}api/v4/" : "#{instance_url}/api/v4/"
    uri = URI.join(api_base, "projects/#{encoded_project_id}/repository/tree")
    uri.query = URI.encode_www_form(
      recursive: "true",
      ref: ref,
      per_page: per_page,
      page: page
    )
    uri
  end

  def with_retries(uri)
    attempt = 0

    loop do
      begin
        return yield
      rescue HttpError => e
        raise unless RETRYABLE_STATUSES.include?(e.status) && attempt < @max_retries

        sleep((2**attempt) + rand)
        attempt += 1
      rescue StandardError
        raise if attempt >= @max_retries

        sleep((2**attempt) + rand)
        attempt += 1
      end
    end
  end

  def perform_get(uri)
    with_retries(uri) do
      request = Net::HTTP::Get.new(uri)
      request["PRIVATE-TOKEN"] = @token
      request["Accept"] = "application/json"
      request["User-Agent"] = @user_agent

      response = Net::HTTP.start(
        uri.host,
        uri.port,
        use_ssl: uri.scheme == "https",
        open_timeout: @open_timeout,
        read_timeout: @read_timeout
      ) do |http|
        http.request(request)
      end

      unless response.is_a?(Net::HTTPSuccess)
        raise HttpError.new(
          "HTTP #{response.code} returned from #{uri}",
          status: response.code.to_i,
          response_body: response.body
        )
      end

      response
    end
  end

  def parse_json(body)
    return [] if body.nil? || body.strip.empty?

    JSON.parse(body)
  rescue JSON::ParserError => e
    raise HttpError.new("Failed to parse GitLab response JSON: #{e.message}", status: 0, response_body: body)
  end
end

class DxApiError < StandardError; end

class DxCatalogClient
  def initialize(token:, api_base_url: "https://api.getdx.com", open_timeout: 10, read_timeout: 30)
    @token = token
    @api_base_url = api_base_url
    @open_timeout = open_timeout
    @read_timeout = read_timeout
  end

  def fetch_service_gitlab_repo_aliases
    aliases = []
    cursor = nil

    loop do
      payload = list_gitlab_repository_entities_page(cursor:)
      entities = payload.fetch("entities", [])
      entities.each do |entity|
        aliases.concat(extract_gitlab_repo_aliases(entity))
      end

      cursor = payload.dig("response_metadata", "next_cursor").to_s.strip
      break if cursor.empty?
    end

    aliases.uniq { |entry| [entry[:url], entry[:identifier], entry[:name]] }
  end

  private

  def list_gitlab_repository_entities_page(cursor:)
    uri = URI.join(normalized_api_base_url, "catalog.entities.list")
    params = { type: "gitlab-repository", limit: 50 }
    params[:cursor] = cursor unless cursor.nil? || cursor.empty?
    uri.query = URI.encode_www_form(params)

    response = Net::HTTP.start(
      uri.host,
      uri.port,
      use_ssl: uri.scheme == "https",
      open_timeout: @open_timeout,
      read_timeout: @read_timeout
    ) do |http|
      request = Net::HTTP::Get.new(uri)
      request["Accept"] = "application/json"
      request["Authorization"] = "Bearer #{@token}"
      http.request(request)
    end

    unless response.is_a?(Net::HTTPSuccess)
      raise DxApiError, "DX API HTTP #{response.code} returned from #{uri}"
    end

    payload = JSON.parse(response.body)
    unless payload["ok"] == true
      raise DxApiError, "DX API returned ok=false"
    end

    payload
  rescue JSON::ParserError => e
    raise DxApiError, "Failed to parse DX API JSON response: #{e.message}"
  end

  def normalized_api_base_url
    @api_base_url.end_with?("/") ? @api_base_url : "#{@api_base_url}/"
  end

  def extract_gitlab_repo_aliases(entity)
    aliases = entity.fetch("aliases", {})
    return [] unless aliases.is_a?(Hash)

    gitlab_aliases = aliases.fetch("gitlab_repo", [])
    return [] unless gitlab_aliases.is_a?(Array)

    gitlab_aliases.filter_map do |alias_entry|
      next unless alias_entry.is_a?(Hash)

      url = alias_entry.fetch("url", "").to_s.strip
      identifier = alias_entry.fetch("identifier", "").to_s.strip
      name = alias_entry.fetch("name", "").to_s.strip
      next if url.empty? && identifier.empty? && name.empty?

      { url:, identifier:, name: }
    end
  end

  def url_like?(value)
    return false if value.to_s.strip.empty?

    normalized = value.to_s.strip
    normalized.match?(%r{\Ahttps?://}i) || normalized.match?(%r{\A[^/\s]+\.[^/\s]+/.+})
  end
end

def parse_options(argv)
  options = {
    output_csv: "tmp/gitlab_repository_files.csv",
    gitlab_token: ENV["GITLAB_TOKEN"].to_s.strip,
    dx_token: ENV.fetch("DX_API_TOKEN", ENV.fetch("DX_TOKEN", "")).to_s.strip,
    dx_api_base_url: ENV.fetch("DX_API_BASE_URL", "https://api.getdx.com").to_s.strip,
    default_instance_url: ENV.fetch("GITLAB_INSTANCE_URL", "https://gitlab.com/").to_s.strip,
    per_page: 100,
    dry_run: false,
    project_limit: nil,
    verbose: false
  }

  parser = OptionParser.new do |opts|
    opts.banner = "Usage: bundle exec ruby sync_gitlab_repository_files_csv.rb [options]"

    opts.on("--output-csv PATH", "Output CSV path (default: tmp/gitlab_repository_files.csv)") do |value|
      options[:output_csv] = value.to_s.strip
    end
    opts.on("--gitlab-token VALUE", "GitLab API token (default: GITLAB_TOKEN env var)") do |value|
      options[:gitlab_token] = value.to_s.strip
    end
    opts.on("--dx-token VALUE", "DX API token (default: DX_API_TOKEN or DX_TOKEN env var)") do |value|
      options[:dx_token] = value.to_s.strip
    end
    opts.on("--dx-api-base-url URL", "DX API base URL (default: DX_API_BASE_URL or https://api.getdx.com)") do |value|
      options[:dx_api_base_url] = value.to_s.strip
    end
    opts.on("--per-page N", Integer, "GitLab page size (default: 100, max: 100)") do |value|
      options[:per_page] = value
    end
    opts.on("--default-instance-url URL", "Fallback GitLab base URL for non-URL aliases (default: GITLAB_INSTANCE_URL or https://gitlab.com/)") do |value|
      options[:default_instance_url] = value.to_s.strip
    end
    opts.on("--project-limit N", Integer, "Limit number of repository aliases processed") do |value|
      options[:project_limit] = value
    end
    opts.on("--dry-run", "List repositories only (no GitLab requests or CSV output rows)") { options[:dry_run] = true }
    opts.on("--verbose", "Print per-project progress") { options[:verbose] = true }
    opts.on("-h", "--help", "Show help") do
      puts opts
      exit(0)
    end
  end

  parser.parse!(argv)

  if options[:output_csv].empty?
    raise OptionParser::MissingArgument, "--output-csv must not be empty"
  end

  if options[:dx_token].empty?
    raise OptionParser::MissingArgument, "DX_API_TOKEN (or DX_TOKEN) is required (or pass --dx-token)"
  end

  if options[:dx_api_base_url].empty?
    raise OptionParser::MissingArgument, "--dx-api-base-url must not be empty"
  end

  if options[:default_instance_url].empty?
    raise OptionParser::MissingArgument, "--default-instance-url must not be empty"
  end

  unless options[:dry_run]
    if options[:gitlab_token].empty?
      raise OptionParser::MissingArgument, "GITLAB_TOKEN environment variable is required (or pass --gitlab-token)"
    end
  end

  if options[:per_page].to_i <= 0 || options[:per_page].to_i > 100
    raise OptionParser::InvalidArgument, "--per-page must be between 1 and 100"
  end

  if options[:project_limit] && options[:project_limit].to_i <= 0
    raise OptionParser::InvalidArgument, "--project-limit must be greater than 0"
  end

  options
end

def normalize_repo_identifier(value)
  normalized = value.to_s.strip
  return "" if normalized.empty?

  normalized = normalized.sub(%r{\Ahttps?://[^/]+/}i, "")
  normalized = normalized.sub(%r{\A/}, "")
  normalized = normalized.sub(/\.git\z/i, "")
  normalized.downcase
end

def url_like?(value)
  return false if value.to_s.strip.empty?

  normalized = value.to_s.strip
  normalized.match?(%r{\Ahttps?://}i) || normalized.match?(%r{\A[^/\s]+\.[^/\s]+/.+})
end

def parse_repo_alias(alias_entry, default_instance_url:)
  url = alias_entry.fetch(:url, "").to_s.strip
  identifier = alias_entry.fetch(:identifier, "").to_s.strip
  name = alias_entry.fetch(:name, "").to_s.strip

  project_source_id = normalize_repo_identifier(identifier)
  project_source_id = normalize_repo_identifier(name) if project_source_id.empty?

  instance_url = default_instance_url

  if url_like?(url)
    normalized_url = url.match?(%r{\Ahttps?://}i) ? url : "https://#{url}"
    uri = URI.parse(normalized_url)
    path_source_id = normalize_repo_identifier(uri.path)
    project_source_id = path_source_id if project_source_id.empty?

    parsed_instance_url = "#{uri.scheme}://#{uri.host}"
    parsed_instance_url = "#{parsed_instance_url}:#{uri.port}" if uri.port && ![80, 443].include?(uri.port)
    instance_url = "#{parsed_instance_url}/"
  end

  return nil if project_source_id.empty?

  { project_source_id:, instance_url: }
rescue URI::InvalidURIError
  nil
end

def build_project_targets(alias_identifiers, default_instance_url:, project_limit:)
  deduped = {}
  targets = []

  alias_identifiers.each do |identifier|
    parsed = parse_repo_alias(identifier, default_instance_url:)
    next if parsed.nil?

    dedupe_key = "#{parsed[:instance_url].downcase}|#{parsed[:project_source_id]}"
    next if deduped.key?(dedupe_key)

    deduped[dedupe_key] = true
    targets << parsed
    break if project_limit && targets.length >= project_limit.to_i
  end

  targets
end

def build_csv_rows(project_id:, entries:)
  files_by_path = {}

  entries.each do |entry|
    next unless entry["type"] == "blob"

    file_path = entry["path"].to_s
    next if file_path.strip.empty?

    mode = entry["mode"].to_s
    sha = entry["id"].to_s
    files_by_path[file_path] = {
      project_id: project_id,
      file_path: file_path,
      mode: mode,
      sha: sha
    }
  end

  files_by_path.values
end

def run(options)
  projects_seen = 0
  projects_succeeded = 0
  projects_failed = 0
  total_rows_exported = 0

  gitlab_client = GitlabClient.new(
    token: options[:gitlab_token],
    user_agent: "gitlab-repository-files-sync/1.0"
  )
  dx_catalog_client = DxCatalogClient.new(
    token: options[:dx_token],
    api_base_url: options[:dx_api_base_url]
  )

  service_gitlab_repos = dx_catalog_client.fetch_service_gitlab_repo_aliases
  puts "Loaded #{service_gitlab_repos.length} gitlab_repo aliases from DX service entities."
  projects = build_project_targets(
    service_gitlab_repos,
    default_instance_url: options[:default_instance_url],
    project_limit: options[:project_limit]
  )
  puts "Selected #{projects.length} unique repositories from DX aliases."

  csv = nil
  unless options[:dry_run]
    FileUtils.mkdir_p(File.dirname(options[:output_csv]))
    csv = CSV.open(options[:output_csv], "w")
    csv << ["project_id", "file_path", "mode", "sha"]
  end

  projects.each do |row|
    projects_seen += 1

    begin
      if options[:dry_run]
        puts "[DRY-RUN] source_id=#{row[:project_source_id]} instance_url=#{row[:instance_url]}"
        projects_succeeded += 1
        next
      end

      metadata = gitlab_client.fetch_project_metadata(
        instance_url: row[:instance_url],
        project_source_id: row[:project_source_id]
      )
      project_id = metadata.fetch(:project_id)
      default_branch = metadata.fetch(:default_branch)
      raise "Missing default_branch for source_id=#{row[:project_source_id]}" if default_branch.empty?

      entries = []
      gitlab_client.fetch_tree_entries(
        instance_url: row[:instance_url],
        project_source_id: row[:project_source_id],
        ref: default_branch,
        per_page: options[:per_page]
      ) do |entry|
        entries << entry
      end

      csv_rows = build_csv_rows(project_id:, entries:)
      csv_rows.each do |export_row|
        csv << [export_row[:project_id], export_row[:file_path], export_row[:mode], export_row[:sha]]
      end

      row_count = csv_rows.length
      total_rows_exported += row_count
      projects_succeeded += 1

      if options[:verbose]
        puts "Exported project_id=#{project_id} source_id=#{row[:project_source_id]} branch=#{default_branch} rows=#{row_count}"
      end
    rescue StandardError => e
      projects_failed += 1
      warn "Failed project row #{row.inspect}: #{e.class}: #{e.message}"
    end
  end

  csv&.close

  if options[:dry_run]
    puts "[DRY-RUN] Skipped CSV file write."
  else
    puts "Wrote CSV output to #{options[:output_csv]}"
  end

  puts "Done. projects_seen=#{projects_seen} projects_succeeded=#{projects_succeeded} projects_failed=#{projects_failed} rows_exported=#{total_rows_exported}"
end

begin
  options = parse_options(ARGV)
  run(options)
rescue OptionParser::ParseError, OptionParser::MissingArgument, OptionParser::InvalidArgument => e
  warn "Argument error: #{e.message}"
  warn "Use --help for usage details."
  exit 2
rescue HttpError => e
  warn "HTTP error: #{e.message}"
  warn "Response: #{e.response_body}" if e.response_body
  exit 1
rescue StandardError => e
  warn "Fatal error: #{e.class}: #{e.message}"
  exit 1
end