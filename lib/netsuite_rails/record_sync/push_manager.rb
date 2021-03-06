module NetSuiteRails
  module RecordSync

    class PushManager
      class << self

        def push(local_record, opts = {})
          # TODO check to see if anything is changed before moving forward
          # if changes_keys.blank? && local_record.netsuite_manual_fields

          # always include the full netsuite field mapping, regardless of which
          # fields were modfified locally, when initially creating the netsuite record

          if opts[:modified_fields] && !local_record.new_netsuite_record?
            # if Array, we need to convert info fields hash based on the record definition
            if opts[:modified_fields].is_a?(Array)
              opts[:modified_fields] = all_netsuite_fields(local_record).select { |k,v| opts[:modified_fields].include?(k) }
            end
          else
            opts[:modified_fields] = modified_local_fields(local_record)
          end

          netsuite_record = build_netsuite_record(local_record, opts)

          local_record.netsuite_execute_callbacks(local_record.class.before_netsuite_push, netsuite_record)

          if opts[:push_method] == :upsert || local_record.new_netsuite_record?
            push_add(local_record, netsuite_record, opts)
          else
            push_update(local_record, netsuite_record, opts)
          end

          local_record.netsuite_execute_callbacks(local_record.class.after_netsuite_push, netsuite_record)

          true
        end

        def push_add(local_record, netsuite_record, opts = {})
          # push_method is either :add or :upsert
          if netsuite_record.send(opts[:push_method] || :add)
            Rails.logger.info "NetSuite: action=#{opts[:push_method]}, local_record=#{local_record.class}[#{local_record.id}]" +
                              "netsuite_record_type=#{netsuite_record.class}, netsuite_record_id=#{netsuite_record.internal_id}"

            if is_active_record_model?(local_record)
              # update_column to avoid triggering another save
              local_record.update_column(:netsuite_id, netsuite_record.internal_id)
            else
              netsuite_record.internal_id
            end
          else
            raise "NetSuite: error. action=#{opts[:push_method]}, netsuite_record_type=#{netsuite_record.class}, errors=#{netsuite_record.errors}"
          end
        end

        def push_update(local_record, netsuite_record, opts = {})
          # build change hash to limit the number of fields pushed to NS on change
          # NS could have logic which could change field functionality depending on
          # input data; it's safest to limit the number of field changes pushed to NS

          # exclude fields that map to procs: they don't indicate which netsuite field
          # the local rails field maps to, so the user must specify this manually in `netsuite_manual_fields`

          # TODO add option for model to mark `custom_field_list = true` if custom field mapping to a
          #      proc is detected. This is helpful for users mapping a local field to a custom field

          custom_field_list = local_record.netsuite_field_map[:custom_field_list] || {}
          custom_field_list = custom_field_list.select { |local_field, netsuite_field| !netsuite_field.is_a?(Proc) }

          modified_fields_list = opts[:modified_fields]
          modified_fields_list = modified_fields_list.select { |local_field, netsuite_field| !netsuite_field.is_a?(Proc) }

          update_list = {}

          modified_fields_list.each do |local_field, netsuite_field|
            if custom_field_list.keys.include?(local_field)
              # if custom field has changed, mark and copy over customFieldList later
              update_list[:custom_field_list] = true
            else
              update_list[netsuite_field] = netsuite_record.send(netsuite_field)
            end
          end

          # manual field list is for fields manually defined on the NS record
          # outside the context of ActiveRecord (e.g. in a before_netsuite_push)

          (local_record.netsuite_manual_fields || []).each do |netsuite_field|
            if netsuite_field == :custom_field_list
              update_list[:custom_field_list] = true
            else
              update_list[netsuite_field] = netsuite_record.send(netsuite_field)
            end
          end

          if update_list[:custom_field_list]
            update_list[:custom_field_list] = netsuite_record.custom_field_list
          end

          if local_record.netsuite_custom_record?
            update_list[:rec_type] = netsuite_record.rec_type
          end

          Rails.logger.info "NetSuite: Update #{netsuite_record.class} #{netsuite_record.internal_id}, list #{update_list.keys}"

          # don't update if list is empty
          return if update_list.empty?

          if netsuite_record.update(update_list)
            true
          else
            raise "NetSuite: error updating record #{netsuite_record.errors}"
          end
        end

        def build_netsuite_record(local_record, opts = {})
          netsuite_record = build_netsuite_record_reference(local_record, opts)

          all_field_list = opts[:modified_fields]
          custom_field_list = local_record.netsuite_field_map[:custom_field_list] || {}
          field_hints = local_record.netsuite_field_hints

          reflections = relationship_attributes_list(local_record)

          all_field_list.each do |local_field, netsuite_field|
            # allow Procs as field mapping in the record definition for custom mapping
            if netsuite_field.is_a?(Proc)
              netsuite_field.call(local_record, netsuite_record, :push)
              next
            end

            # TODO pretty sure this will break if we are dealing with has_many

            netsuite_field_value = if reflections.has_key?(reflections.keys.first.class == String ? local_field.to_s : local_field)
              if (remote_internal_id = local_record.send(local_field).try(:netsuite_id)).present?
                { internal_id: remote_internal_id }
              else
                nil
              end
            else
              local_record.send(local_field)
            end

            if field_hints.has_key?(local_field) && netsuite_field_value.present?
              netsuite_field_value = NetSuiteRails::Transformations.transform(field_hints[local_field], netsuite_field_value, :push)
            end

            # TODO should we skip setting nil values completely? What if we want to nil out fields on update?

            # be wary of API version issues: https://github.com/NetSweet/netsuite/issues/61

            if custom_field_list.keys.include?(local_field)
              netsuite_record.custom_field_list.send(:"#{netsuite_field}=", netsuite_field_value)
            else
              netsuite_record.send(:"#{netsuite_field}=", netsuite_field_value)
            end
          end

          netsuite_record
        end

        def build_netsuite_record_reference(local_record, opts = {})
          # must set internal_id for records on new; will be set to nil if new record

          init_hash = if opts[:use_external_id]
            { external_id: local_record.netsuite_external_id }
          else
            { internal_id: local_record.netsuite_id }
          end

          netsuite_record = local_record.netsuite_record_class.new(init_hash)

          if local_record.netsuite_custom_record?
            netsuite_record.rec_type = NetSuite::Records::CustomRecord.new(internal_id: local_record.class.netsuite_custom_record_type_id)
          end

          netsuite_record
        end

        def modified_local_fields(local_record)
          synced_netsuite_fields = all_netsuite_fields(local_record)

          changed_keys = if is_active_record_model?(local_record)
            changed_attributes(local_record)
          else
            local_record.changed_attributes
          end

          # filter out unchanged keys when updating record
          unless local_record.new_netsuite_record?
            synced_netsuite_fields.select! { |k,v| changed_keys.include?(k) }
          end

          synced_netsuite_fields
        end

        def all_netsuite_fields(local_record)
          custom_netsuite_field_list = local_record.netsuite_field_map[:custom_field_list] || {}
          standard_netsuite_field_list = local_record.netsuite_field_map.except(:custom_field_list) || {}

          custom_netsuite_field_list.merge(standard_netsuite_field_list)
        end

        def changed_attributes(local_record)
          # otherwise filter only by attributes that have been changed
          # limiting the delta sent to NS will reduce hitting edge cases

          # TODO think about has_many / join table changes

          reflections = relationship_attributes_list(local_record)

          association_field_key_mapping = reflections.values.reject(&:collection?).inject({}) do |h, a|
            begin
              h[a.association_foreign_key.to_sym] = a.name
            rescue Exception => e
              # occurs when `has_one through:` exists on a record but `through` is not a valid reference
              Rails.logger.error "NetSuite: error detecting foreign key #{a.name}"
            end

            h
          end

          changed_attributes_keys = local_record.changed_attributes.keys

          serialized_attrs = if NetSuiteRails.rails4?
            local_record.class.serialized_attributes
          else
            local_record.serialized_attributes
          end

          # changes_attributes does not track serialized attributes, although it does track the storage key
          # if a serialized attribute storage key is dirty assume that all keys in the hash are dirty as well

          changed_attributes_keys += serialized_attrs.keys.map do |k|
            local_record.send(k.to_sym).keys.map(&:to_s)
          end.flatten

          # convert relationship symbols from :object_id to :object
          changed_attributes_keys.map do |k|
            association_field_key_mapping[k.to_sym] || k.to_sym
          end
        end

        def relationship_attributes_list(local_record)
          if is_active_record_model?(local_record)
            if NetSuiteRails.rails4?
              local_record.class.reflections
            else
              local_record.reflections
            end
          else
            local_record.respond_to?(:reflections) ? local_record.reflections : {}
          end
        end

        def is_active_record_model?(local_record)
          defined?(::ActiveRecord::Base) && local_record.class.ancestors.include?(ActiveRecord::Base)
        end

      end
    end

  end
end
