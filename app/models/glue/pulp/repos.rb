#
# Copyright 2011 Red Hat, Inc.
#
# This software is licensed to you under the GNU General Public
# License as published by the Free Software Foundation; either version
# 2 of the License (GPLv2) or (at your option) any later version.
# There is NO WARRANTY for this software, express or implied,
# including the implied warranties of MERCHANTABILITY,
# NON-INFRINGEMENT, or FITNESS FOR A PARTICULAR PURPOSE. You should
# have received a copy of GPLv2 along with this software; if not, see
# http://www.gnu.org/licenses/old-licenses/gpl-2.0.txt.

require 'http_resource'
require 'resources/pulp'
require 'resources/cdn'
require 'openssl'

module Glue::Pulp::Repos

  def self.included(base)
    base.send :include, InstanceMethods
    base.class_eval do
      before_save :save_repos_orchestration
      before_destroy :destroy_repos_orchestration

      has_and_belongs_to_many :filters, :uniq => true, :before_add => :add_filters_orchestration, :before_remove => :remove_filters_orchestration

      # required for GPG key url generation
      include Rails.application.routes.url_helpers
    end
  end

  def self.groupid(product, environment, content = nil)
      groups = [self.product_groupid(product), self.env_groupid(environment), self.org_groupid(product.locker.organization)]
      groups << self.content_groupid(content) if content
      groups
  end

  def self.clone_repo_path(repo, environment, for_cp = false)
    org, env, content_path = repo.relative_path.split("/",3)
    if for_cp
      "/#{content_path}"
    else
      "#{org}/#{environment.name}/#{content_path}"
    end
  end

  def self.repo_path_from_content_path(environment, content_path)
    content_path = content_path.sub(/^\//, "")
    "#{environment.organization.name}/#{environment.name}/#{content_path}"
  end

  # create content for custom repo
  def create_content(repo)
    new_content = Glue::Candlepin::ProductContent.new({
      :content => {
        :name => repo.name,
        :contentUrl => Glue::Pulp::Repos.custom_content_path(self, repo.name),
        :gpgUrl => yum_gpg_key_url(repo),
        :type => "yum",
        :label => "#{self.id}-#{repo.name}",
        :vendor => Provider::CUSTOM
      },
      :enabled => true
    })
    new_content.create
    add_content new_content
    new_content.content
  end

  # repo path for custom product repos (RH repo paths are derivated from
  # content url)
  def self.custom_repo_path(environment, product, name)
    prefix = [environment.organization.name,environment.name].map{|x| x.gsub(/[^-\w]/,"_") }.join("/")
    prefix + custom_content_path(product, name)
  end

  def self.custom_content_path(product, name)
    parts = []
    # We generate repo path only for custom product content. We add this
    # constant string to avoid colisions with RH content. RH content url
    # begins usually with something like "/content/dist/rhel/...".
    # There we prefix custom content/repo url with "/custom/..."
    parts << "custom"
    parts += [product.name,name]
    "/" + parts.map{|x| x.gsub(/[^-\w]/,"_") }.join("/")
  end

  def self.clone_repo_path_for_cp(repo)
    self.clone_repo_path(repo, nil, true)
  end


  def self.org_groupid(org)
      "org:#{org.id}"
  end

  def self.env_groupid(environment)
      "env:#{environment.id}"
  end

  def self.product_groupid(product)
      "product:#{product.cp_id}"
  end

  def self.content_groupid(content)
      "content:#{content.id}"
  end

  def self.prepopulate! products, environment, repos=[]
    full_repos = Pulp::Repository.all
    products.each{|prod|
      prod.repos(environment, true).each{|repo|
        repo.populate_from(full_repos)
      }
    }
    repos.each{|repo|
      repo.populate_from(full_repos)
    }
  end

  module InstanceMethods

    def empty?
      return self.repos(locker).empty?
    end


    def repos env, include_disabled = false
      @repo_cache = {} if @repo_cache.nil?
      #cache repos so we can cache lazy_accessors
      if @repo_cache[env.id].nil?
        @repo_cache[env.id] = Repository.joins(:environment_product).where(
            "environment_products.product_id" => self.id, "environment_products.environment_id"=> env)
      end
      if self.custom? || include_disabled
        return @repo_cache[env.id]
      end

      # we only want the enabled repos to be visible
      # This serves as a white list for redhat repos
      @repo_cache[env.id].where(:enabled => true)
    end

    def promote from_env, to_env
      @orchestration_for = :promote

      async_tasks = promote_repos repos(from_env), from_env, to_env
      if !to_env.products.include? self
        self.environments << to_env
      end

      save!
      async_tasks
    end

    def package_groups env, search_args = {}
      groups = []
      self.repos(env).each do |repo|
        groups << repo.package_groups(search_args)
      end
      groups.flatten(1)
    end

    def package_group_categories env, search_args = {}
      categories = []
      self.repos(env).each do |repo|
        categories << repo.package_group_categories(search_args)
      end
      categories.flatten(1)
    end

    def has_package? id
      self.repos(env).each do |repo|
        return true if repo.has_package? id
      end
      false
    end

    def find_packages_by_name env, name
      self.repos(env).collect do |repo|
        repo.find_packages_by_name(name).collect do |p|
          p[:repo_id] = repo.id
          p
        end
      end.flatten(1)
    end

    def find_packages_by_nvre env, name, version, release, epoch
      self.repos(env).collect do |repo|
        repo.find_packages_by_nvre(name, version, release, epoch).collect do |p|
          p[:repo_id] = repo.id
          p
        end
      end.flatten(1)
    end

    def distributions env
      to_ret = []
      self.repos(env).each{|repo|
        distros = repo.distributions
        to_ret = to_ret +  distros if !distros.empty?
      }
      to_ret
    end

    def get_distribution env, id
      self.repos(env).map do |repo|
        repo.distributions.find_all {|d| d.id == id }
      end.flatten(1)
    end

    def find_latest_packages_by_name env, name

      packs = self.repos(env).collect do |repo|
        repo.find_latest_packages_by_name(name).collect do |pack|
          pack[:repo_id] = repo.id
          pack
        end
      end.flatten(1)

      Katello::PackageUtils.find_latest_packages packs
    end

    def has_erratum? id
      self.repos(env).each do |repo|
        return true if repo.has_erratum? id
      end
      false
    end

    def promoted_to? target_env
      target_env.products.include? self
    end

    def sync
      Rails.logger.info "Syncing product #{name}"
      self.repos(locker).collect do |r|
        r.sync
      end.flatten
    end

    def synced?
      self.repos(locker).any? { |r| r.synced? }
    end

    #get last sync status of all repositories in this product
    def latest_sync_statuses
      self.repos(locker).collect do |r|
        r._get_most_recent_sync_status()
      end
    end

    # Get the most relavant status for all the repos in this Product
    def sync_status
      return @status if @status

      statuses = repos(self.locker).map {|r| r.sync_status()}
      return ::PulpSyncStatus.new(:state => ::PulpSyncStatus::Status::NOT_SYNCED) if statuses.empty?

      #if any of repos sync still running -> product sync running
      idx = statuses.index do |r| r.state.to_s == ::PulpSyncStatus::Status::RUNNING.to_s end
      return statuses[idx] if idx != nil

      #else if any of repos not synced -> product not synced
      idx = statuses.index do |r| r.state.to_s == ::PulpSyncStatus::Status::NOT_SYNCED.to_s end
      return statuses[idx] if idx != nil

      #else if any of repos sync cancelled -> product sync cancelled
      idx = statuses.index do |r| r.state.to_s == ::PulpSyncStatus::Status::CANCELED.to_s end
      return statuses[idx] if idx != nil

      #else if any of repos sync finished with error -> product sync finished with error
      idx = statuses.index do |r| r.state.to_s == ::PulpSyncStatus::Status::ERROR.to_s end
      return statuses[idx] if idx != nil

      #else -> all finished
      @status = statuses[0]
    end

    def sync_state
      self.sync_status().state
    end

    def sync_start
      start_times = Array.new
      for r in repos(locker)
        start = r.sync_start
        start_times << start unless start.nil?
      end
      start_times.sort!
      start_times.last
    end

    def sync_finish
      finish_times = Array.new
      for r in repos(locker)
        finish = r.sync_finish
        finish_times << finish unless finish.nil?
      end
      finish_times.sort!
      finish_times.last
    end

    def sync_size
      size = self.repos(locker).inject(0) { |sum,v| sum + v.sync_status.progress.total_size }
    end

    def last_sync
      sync_times = Array.new
      for r in repos(locker)
        sync = r.last_sync
        sync_times << sync unless sync.nil?
      end
      sync_times.sort!
      sync_times.last
    end

    def cancel_sync
      Rails.logger.info "Cancelling synchronization of product #{name}"
      for r in repos(locker)
        r.cancel_sync
      end
    end

    def repo_id(content_name, env_name = nil)
      return content_name if content_name.include?(self.organization.name) && content_name.include?(self.name.to_s)
      Glue::Pulp::Repo.repo_id(self.name.to_s, content_name.to_s, env_name, self.organization.name)
    end

    def repo_url(content_url)
      if self.provider.provider_type == Provider::CUSTOM
        url = content_url.dup
      else
        url = self.provider[:repository_url] + content_url
      end
      url
    end

    def delete_repo_by_id(repo_id)
      Repository.destroy_all(:id=>repo_id)
    end

    def add_repo(name, url, repo_type, gpg = nil)
      check_for_repo_conflicts(name)
      key = EnvironmentProduct.find_or_create(self.organization.locker, self)
      repo = Repository.create!(:environment_product => key, :pulp_id => repo_id(name),
          :groupid => Glue::Pulp::Repos.groupid(self, self.locker),
          :relative_path => Glue::Pulp::Repos.custom_repo_path(self.locker, self, name),
          :arch => arch,
          :name => name,
          :feed => url,
          :content_type => repo_type,
          :gpg_key => gpg
      )
      content = create_content(repo)
      Pulp::Repository.update(repo.pulp_id, :addgrp => Glue::Pulp::Repos.content_groupid(content))
      repo
    end

    def setup_sync_schedule

      schedule = (self.sync_plan && self.sync_plan.schedule_format) || nil
      self.repos(self.locker).each do |repo|
        repo.set_sync_schedule(schedule)
      end
    end


    def set_repos
      content_urls = self.productContent.map { |pc| pc.content.contentUrl }
      cdn_var_substitutor = CDN::CdnVarSubstitutor.new(self.provider[:repository_url],
                                                       :ssl_client_cert => OpenSSL::X509::Certificate.new(self.certificate),
                                                       :ssl_client_key => OpenSSL::PKey::RSA.new(self.key))
      cdn_var_substitutor.precalculate(content_urls)

      self.productContent.collect do |pc|
        ca = File.read(CDN::CdnResource.ca_file)

        cdn_var_substitutor.substitute_vars(pc.content.contentUrl).each do |(substitutions, path)|
          feed_url = repo_url(path)
          arch = substitutions["basearch"] || "noarch"
          repo_name = [pc.content.name, substitutions.sort_by {|k,_| k.to_s}.map(&:last)].flatten.compact.join(" ").gsub(/[^a-z0-9\-_ ]/i,"")
          version = CDN::Utils.parse_version(substitutions["releasever"])

          begin
            env_prod = EnvironmentProduct.find_or_create(self.organization.locker, self)
            repo = Repository.create!(:environment_product=> env_prod, :pulp_id => repo_id(repo_name),
                                        :arch => arch,
                                        :major => version[:major],
                                        :minor => version[:minor],
                                        :relative_path => Glue::Pulp::Repos.repo_path_from_content_path(self.locker, path),
                                        :name => repo_name,
                                        :feed => feed_url,
                                        :feed_ca => ca,
                                        :feed_cert => self.certificate,
                                        :feed_key => self.key,
                                        :content_type => pc.content.type,
                                        :groupid => Glue::Pulp::Repos.groupid(self, self.locker, pc.content),
                                        :preserve_metadata => true, #preserve repo metadata when importing from cp
                                        :enabled =>false
                                        )

          rescue RestClient::InternalServerError => e
            if e.message.include? "Architecture must be one of"
              Rails.logger.error("Pulp does not support arch '#{arch}'")
            else
              raise e
            end
          end
        end
      end
    end

    def update_repos
      return true unless productContent_changed?

      deleted_content.each do |pc|
        Rails.logger.debug "deleting repository #{pc.content.label}"
        Repository.destroy_all(:pulp_id => repo_id(pc.content.name))
      end

      added_content.each do |pc|
        if !(self.environments.map(&:name).any? {|name| pc.content.name.include?(name)}) || pc.content.name.include?('Locker')
          Rails.logger.debug "creating repository #{repo_id(pc.content.name)}"
          self.add_repo(pc.content.name, repo_url(pc.content.contentUrl), pc.content.type)
        else
          raise "new content was added to environment other than Locker. use promotion instead."
        end
      end

      #
      # TODO: candlepin currently doesn't support modification of content
      #
      #common_content_ids = (old_content_ids & new_content_ids)
      #changed_content = self.productContent_change[1].select do |new_pc|
      #  common_content_ids.include?(new_pc.id) && productContent_change[0].any? do |old_pc|
      #    old_pc.id == new_pc.id && old_pc.content.contentUrl != new_pc.content.contentUrl
      #  end
      #end
      #
      #changed_content.each do |pc|
      #  Pulp::Repository.update(repo_id(pc.content.name), {
      #    :feed => repo_url(pc.content.contentUrl)
      #  })
      #end
    end

    def del_repos
      #destroy all repos in all environmnents
      Rails.logger.debug "deleting all repositoris in product #{name}"
      self.environments.each do |env|
        self.repos(env).each do |repo|
          repo.destroy
        end
      end
      true
    end

    def save_repos_orchestration
      case orchestration_for
        when :create
          # no repositories are added when a product is created
        when :import_from_cp
          queue.create(:name => "create pulp repositories for product: #{self.name}",      :priority => 1, :action => [self, :set_repos])
        when :update
          #called when sync schedule changed, repo added, repo deleted
          queue.create(:name => "setting up pulp sync schedule for product: #{self.name}", :priority => 2, :action => [self, :setup_sync_schedule])
        when :promote
          # do nothing, as repos have already been promoted (see promote_repos method)
      end
    end

    def destroy_repos_orchestration
      queue.create(:name => "delete pulp repositories for product: #{self.name}", :priority => 6, :action => [self, :del_repos])
    end

    def add_filters_orchestration(added_filter)
      return true unless environments.size > 1 and promoted_to?(locker.successor)

      self.repos(locker.successor).each do |r|
        queue.create(
            :name => "add filter '#{added_filter.pulp_id}' to repo: #{r.id}",
            :priority => 5,
            :action => [self, :set_filter, r, added_filter.pulp_id])
      end

      @orchestration_for = :add_filter
      on_save
    end

    def remove_filters_orchestration(removed_filter)
      return true unless environments.size > 1 and promoted_to?(locker.successor)

      self.repos(locker.successor).each do |r|
        queue.create(
            :name => "remove filter '#{removed_filter.pulp_id}' from repo: #{r.id}",
            :priority => 5,
            :action => [self, :del_filter, r, removed_filter.pulp_id])
      end

      @orchestration_for = :remove_filter
      on_save
    end

    protected
    def promote_repos repos, from_env, to_env
      async_tasks = []
      repos.each do |repo|
        if repo.is_cloned_in?(to_env)
          #repo is already cloned, so lets just re-sync it from its parent
          async_tasks << repo.get_clone(to_env).sync
        else
          #repo is not in the next environment yet, we have to clone it there
          if to_env.prior == locker
            async_tasks << repo.promote(to_env, filters.collect {|p| p.pulp_id})
          else
            async_tasks << repo.promote(to_env)
          end
        end
      end
      async_tasks.flatten(1)
    end


    def set_filter repo, filter_id
      repo.add_filters [filter_id]
    end

    def del_filter repo, filter_id
      repo.remove_filters [filter_id]
    end

    def check_for_repo_conflicts(repo_name)
      is_dupe =  Repository.joins(:environment_product).where( :name=> repo_name,
              "environment_products.product_id" => self.id, "environment_products.environment_id"=> self.locker.id).count > 0
      if is_dupe
        raise Errors::ConflictException.new(_("There is already a repo with the name [ %s ] for product [ %s ]") % [repo_name, self.name])
      end
    end

    private

    def yum_gpg_key_url(repo)
      host = AppConfig.host
      host += ":" + AppConfig.port.to_s unless AppConfig.port.blank? || AppConfig.port.to_s == "443"
      gpg_key_content_api_repository_url(repo, :host => host + ENV['RAILS_RELATIVE_URL_ROOT'].to_s, :protocol => 'https')
    end

  end
end