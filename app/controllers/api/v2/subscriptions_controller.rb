#
# Copyright 2013 Red Hat, Inc.
#
# This software is licensed to you under the GNU General Public
# License as published by the Free Software Foundation; either version
# 2 of the License (GPLv2) or (at your option) any later version.
# There is NO WARRANTY for this software, express or implied,
# including the implied warranties of MERCHANTABILITY,
# NON-INFRINGEMENT, or FITNESS FOR A PARTICULAR PURPOSE. You should
# have received a copy of GPLv2 along with this software; if not, see
# http://www.gnu.org/licenses/old-licenses/gpl-2.0.txt.

class Api::V2::SubscriptionsController < Api::V2::ApiController
  include ConsumersControllerLogic

  before_filter :find_system
  before_filter :authorize

  resource_description do
    description "Systems subscriptions management."
    param :system_id, :identifier, :desc => "System uuid", :required => true

    api_version 'v2'
  end

  def rules
    index_test = lambda { @system.readable? }
    available_test = lambda { Organization.any_readable? }
    system_modification_test = lambda { @system.editable? }

    {
      :index => index_test,
      :create => system_modification_test,
      :destroy => system_modification_test,
      :destroy_all => system_modification_test,
      :available => available_test
    }
  end

  api :GET, "/systems/:system_id/subscriptions", "List subscriptions"
  param :system_id, String, :desc => "UUID of the system", :required => true
  def index
    subscriptions = {
        :subscriptions => @system.consumed_entitlements,
        :subtotal => @system.consumed_entitlements.count,
        :total => @system.consumed_entitlements.count
    }

    respond({ :collection => subscriptions })
  end

  api :GET, "/systems/:system_id/subscriptions/available", "List available subscriptions"
  param :system_id, String, :desc => "UUID of the system", :required => true
  def available
    pools = @system.filtered_pools(current_user.subscriptions_match_system_preference,
      current_user.subscriptions_match_installed_preference,
      current_user.subscriptions_no_overlap_preference)

    available = available_subscriptions(pools, @system.organization)

    collection = {
        :subscriptions => available,
        :subtotal => available.count,
        :total => available.count
    }

    respond_for_index({ :collection => collection, :template => :index })
  end

  api :POST, "/systems/:system_id/subscriptions", "Create a subscription"
  param :system_id, String, :desc => "UUID of the system", :required => true
  param :subscription, Hash, :required => true, :action_aware => true do
    param :pool, String, :desc => "Subscription Pool uuid", :required => true
    param :quantity, :number, :desc => "Number of subscription to use", :required => true
  end
  def create
    expected_params = params.slice(:pool, :quantity)
    raise HttpErrors::BadRequest, _("Please provide pool and quantity") if expected_params.count != 2
    @system.subscribe(expected_params[:pool], expected_params[:quantity])
    respond :resource => @system
  end

  api :DELETE, "/systems/:system_id/subscriptions/:id", "Delete a subscription"
  param :id, :number, :desc => "Entitlement id"
  param :system_id, String, :desc => "UUID of the system", :required => true
  def destroy
    expected_params = params.slice(:id)
    raise HttpErrors::BadRequest, _("Please provide subscription ID") if expected_params.count != 1
    @system.unsubscribe(expected_params[:id])
    respond_for_show :resource => @system
  end

  api :DELETE, "/systems/:system_id/subscriptions", "Delete all system subscriptions"
  param :system_id, String, :desc => "UUID of the system", :required => true
  def destroy_all
    @system.unsubscribe_all
    respond_for_show :resource => @system
  end

  protected

  def find_system
    @system = System.first(:conditions => { :uuid => params[:system_id] })
    raise HttpErrors::NotFound, _("Couldn't find system '%s'") % params[:system_id] if @system.nil?
    @system
  end
end
