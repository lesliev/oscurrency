class AddressesController < ApplicationController
  before_filter :login_required
  before_filter :credit_card_required
  before_filter :correct_user_required
  before_action :load_states, only: %i[new edit]

  def index
    @addresses = current_person.addresses
    respond_to do |format|
      format.xml { render :xml => @addresses }
    end
  end

  def new
    @address = Address.new
  end

  def edit
    @address = current_person.addresses.find(params[:id])
  end

  def create
    @address = Address.new(params[:address])
    begin
      if current_person.addresses << @address
        redirect_to person_url(current_person)
      else
        load_states
        render :action => :new
      end
    rescue
      load_states
      flash[:error] = t("error_geocoding_failed")
      render :action => :new
    end
  end

  def update
    @address = current_person.addresses.find(params[:id])
    begin
      if @address.update_attributes(params[:address])
        redirect_to person_url(current_person)
      else
        load_states
        render :action => :edit
      end
    rescue
      load_states
      flash[:error] = t("error_geocoding_failed")
      render :action => :edit
    end
  end

  def destroy
    if current_person.addresses.length > 1
      @address = current_person.addresses.find(params[:id])
      @address.destroy
    else
      flash[:error] = t("error_at_least_one_address")
    end

    respond_to do |format|
      format.html { redirect_to(person_url(current_person)) }
      format.xml  { head :ok }
    end
  end

  def choose
    @address = current_person.addresses.find(params[:id])
    @old_primary_addresses = current_person.addresses.where(primary: true).all
    respond_to do |format|
      if @address.update_attributes!(primary: true)
        @old_primary_addresses.each {|a| a.update_attributes(primary: false)}
        flash[:success] = t('success_profile_updated')
      else
        flash[:error] = t('error_invalid_action')
      end
      format.html { redirect_to(edit_person_path(current_person)) }
    end
  end

  private

  def load_states
    @states ||= State.order(:name).pluck(:name, :id)
  end

  def correct_user_required
    redirect_to home_url unless Person.find(params[:person_id]) == current_person
  end
end
