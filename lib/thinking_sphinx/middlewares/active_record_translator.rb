class ThinkingSphinx::Middlewares::ActiveRecordTranslator <
  ThinkingSphinx::Middlewares::Middleware

  def call(contexts)
    contexts.each do |context|
      Inner.new(context).call
    end

    app.call contexts
  end

  private

  class Inner
    def initialize(context)
      @context = context
    end

    def call
      results_for_models # load now to avoid segfaults

      context[:results] = if sql_options[:order]
        results_for_models.values.first
      else
        context[:results].collect { |row| result_for(row) }
      end
    end

    private

    attr_reader :context

    def ids_for_model(model_name)
      if ModelCRCLookup.use_crc?(context[:results].first)
        model_name_crc = Zlib.crc32(model_name)
        (context[:results].map do |row|
          row['sphinx_internal_id'] if row['class_crc'] == model_name_crc
        end).compact
      else
        (context[:results].map do |row|
          row['sphinx_internal_id'] if row['sphinx_internal_class'] == model_name
        end).compact
      end
    end

    def model_names
      if ModelCRCLookup.use_crc?(context[:results].first)
        @model_names ||= (context[:results].map do |row|
          ModelCRCLookup.lookup(row['class_crc'])
        end).uniq
      else
        @model_names ||= (context[:results].map do |row|
          row['sphinx_internal_class']
        end).uniq
      end
    end

    def reset_memos
      @model_names        = nil
      @results_for_models = nil
    end

    def result_for(row)
      if ModelCRCLookup.use_crc?(row)
        results_for_models[ModelCRCLookup.lookup(row['class_crc'])].detect do |record|
          record.id == row['sphinx_internal_id']
        end
      else
        results_for_models[row['sphinx_internal_class']].detect do |record|
          record.id == row['sphinx_internal_id']
        end
      end
    end

    def results_for_models
      @results_for_models ||= model_names.inject({}) do |hash, name|
        model = name.constantize
        hash[name] = model_relation_with_sql_options(model.unscoped).where(
          (context.configuration.settings[:primary_key] || model.primary_key || :id) => ids_for_model(name)
        )

        hash
      end
    end

    def model_relation_with_sql_options(relation)
      relation = relation.includes sql_options[:include] if sql_options[:include]
      relation = relation.joins  sql_options[:joins]  if sql_options[:joins]
      relation = relation.order  sql_options[:order]  if sql_options[:order]
      relation = relation.select sql_options[:select] if sql_options[:select]
      relation = relation.group  sql_options[:group]  if sql_options[:group]
      relation
    end

    def sql_options
      context.search.options[:sql] || {}
    end
  end

  class ModelCRCLookup
    class ModelNotFound < StandardError; end

    @@crcs = nil

    def self.use_crc?(row)
      row && row.has_key?('class_crc')
    end

    def self.lookup(crc)
      if @@crcs.nil?
        Rails.application.eager_load!
        @@crcs = Hash[ActiveRecord::Base.descendants.map { |klass| [ Zlib.crc32(klass.name), klass.name ] } ]
      end

      @@crcs[crc] || raise(ModelNotFound.new("No Model found for crc: #{crc}"))
    end

    def self.clear
      @@crcs = nil
    end
  end
end
