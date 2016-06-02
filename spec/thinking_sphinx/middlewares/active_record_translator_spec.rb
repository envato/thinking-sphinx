module ThinkingSphinx
  module Middlewares; end
  class  Search; end
end

require 'thinking_sphinx/middlewares/middleware'
require 'thinking_sphinx/middlewares/active_record_translator'
require 'thinking_sphinx/search/stale_ids_exception'

describe ThinkingSphinx::Middlewares::ActiveRecordTranslator do
  let(:app)        { double('app', :call => true) }
  let(:middleware) {
    ThinkingSphinx::Middlewares::ActiveRecordTranslator.new app }
  let(:context)    { {:raw => [], :results => [] } }
  let(:model)      { double('model', :primary_key => :id) }
  let(:search)     { double('search', :options => {}) }
  let(:configuration) { double('configuration', :settings => {:primary_key => :id}) }

  context 'using sphinx internal class' do
    def raw_result(id, model_name)
      {'sphinx_internal_id' => id, 'sphinx_internal_class' => model_name}
    end

    describe '#call' do
      before :each do
        context.stub :search => search
        context.stub :configuration => configuration
        model.stub :unscoped => model
      end

      it "translates records to ActiveRecord objects" do
        model_name = double('article', :constantize => model)
        instance   = double('instance', :id => 24)
        model.stub :where => [instance]

        context[:results] << raw_result(24, model_name)

        middleware.call [context]

        context[:results].should == [instance]
      end

      it "only queries the model once for the given search results" do
        model_name = double('article', :constantize => model)
        instance_a = double('instance', :id => 24)
        instance_b = double('instance', :id => 42)
        context[:results] << raw_result(24, model_name)
        context[:results] << raw_result(42, model_name)

        model.should_receive(:where).once.and_return([instance_a, instance_b])

        middleware.call [context]
      end

      it "handles multiple models" do
        article_model = double('article model', :primary_key => :id)
        article_name  = double('article name', :constantize => article_model)
        article       = double('article instance', :id => 24)

        user_model    = double('user model', :primary_key => :id)
        user_name     = double('user name', :constantize => user_model)
        user          = double('user instance', :id => 12)

        article_model.stub :unscoped => article_model
        user_model.stub :unscoped => user_model

        context[:results] << raw_result(24, article_name)
        context[:results] << raw_result(12, user_name)

        article_model.should_receive(:where).once.and_return([article])
        user_model.should_receive(:where).once.and_return([user])

        middleware.call [context]
      end

      it "sorts the results according to Sphinx order, not database order" do
        model_name = double('article', :constantize => model)
        instance_1 = double('instance 1', :id => 1)
        instance_2 = double('instance 2', :id => 2)

        context[:results] << raw_result(2, model_name)
        context[:results] << raw_result(1, model_name)

        model.stub(:where => [instance_1, instance_2])

        middleware.call [context]

        context[:results].should == [instance_2, instance_1]
      end

      it "returns objects in database order if a SQL order clause is supplied" do
        model_name = double('article', :constantize => model)
        instance_1 = double('instance 1', :id => 1)
        instance_2 = double('instance 2', :id => 2)

        context[:results] << raw_result(2, model_name)
        context[:results] << raw_result(1, model_name)

        model.stub(:order => model, :where => [instance_1, instance_2])
        search.options[:sql] = {:order => 'name DESC'}

        middleware.call [context]

        context[:results].should == [instance_1, instance_2]
      end

      it "handles model without primary key" do
        no_primary_key_model = double('no primary key model')
        no_primary_key_model.stub :unscoped => no_primary_key_model
        model_name = double('article', :constantize => no_primary_key_model)
        instance   = double('instance', :id => 1)
        no_primary_key_model.stub :where => [instance]

        context[:results] << raw_result(1, model_name)

        middleware.call [context]
      end

      context 'SQL options' do
        let(:relation) { double('relation', :where => []) }

        before :each do
          model.stub :unscoped => relation

          model_name = double('article', :constantize => model)
          context[:results] << raw_result(1, model_name)
        end

        it "passes through SQL include options to the relation" do
          search.options[:sql] = {:include => :association}

          relation.should_receive(:includes).with(:association).
            and_return(relation)

          middleware.call [context]
        end

        it "passes through SQL join options to the relation" do
          search.options[:sql] = {:joins => :association}

          relation.should_receive(:joins).with(:association).and_return(relation)

          middleware.call [context]
        end

        it "passes through SQL order options to the relation" do
          search.options[:sql] = {:order => 'name DESC'}

          relation.should_receive(:order).with('name DESC').and_return(relation)

          middleware.call [context]
        end

        it "passes through SQL select options to the relation" do
          search.options[:sql] = {:select => :column}

          relation.should_receive(:select).with(:column).and_return(relation)

          middleware.call [context]
        end

        it "passes through SQL group options to the relation" do
          search.options[:sql] = {:group => :column}

          relation.should_receive(:group).with(:column).and_return(relation)

          middleware.call [context]
        end
      end
    end
  end

  context 'using legacy class_crc' do
    let(:article_name) { double('article name', :constantize => article_model) }
    let(:article_model) { double('article model', :primary_key => :id) }
    let(:user_model)   { double('user model', :primary_key => :id) }
    let(:user_name)    { double('user name', :constantize => user_model) }

    let(:models) { [article_model, user_model] }
    let(:active_record_base) { double('active record base', :descendants => models) }
    let(:rails) { double('rails', :application => double('application', :eager_load! => true)) }

    before { ThinkingSphinx::Middlewares::ActiveRecordTranslator::ModelCRCLookup.clear }

    before { stub_const('ActiveRecord::Base', active_record_base) }
    before { stub_const('Rails', rails) }

    before { (user_model).stub(:name => user_name) }
    before { article_model.stub(:name => article_name) }

    def raw_result(id, model_name)
      {'sphinx_internal_id' => id, 'class_crc' => Zlib.crc32(model_name)}
    end

    describe '#call' do
      before :each do
        context.stub :search => search
        context.stub :configuration => configuration
        model.stub :unscoped => model
        article_model.stub :unscoped => article_model
      end

      it "translates records to ActiveRecord objects" do
        instance   = double('instance', :id => 24)
        article_model.stub :where => [instance]

        context[:results] << raw_result(24, article_name)

        middleware.call [context]

        context[:results].should == [instance]
      end

      it "only queries the model once for the given search results" do
        instance_a = double('instance', :id => 24)
        instance_b = double('instance', :id => 42)
        context[:results] << raw_result(24, article_name)
        context[:results] << raw_result(42, article_name)

        article_model.should_receive(:where).once.and_return([instance_a, instance_b])

        middleware.call [context]
      end

      it "handles multiple models" do
        article       = double('article instance', :id => 24)
        user          = double('user instance', :id => 12)

        article_model.stub :unscoped => article_model
        user_model.stub :unscoped => user_model

        context[:results] << raw_result(24, article_name)
        context[:results] << raw_result(12, user_name)

        article_model.should_receive(:where).once.and_return([article])
        user_model.should_receive(:where).once.and_return([user])

        middleware.call [context]
      end

      it "sorts the results according to Sphinx order, not database order" do
        instance_1 = double('instance 1', :id => 1)
        instance_2 = double('instance 2', :id => 2)

        context[:results] << raw_result(2, article_name)
        context[:results] << raw_result(1, article_name)

        article_model.stub(:where => [instance_1, instance_2])

        middleware.call [context]

        context[:results].should == [instance_2, instance_1]
      end

      it "returns objects in database order if a SQL order clause is supplied" do
        instance_1 = double('instance 1', :id => 1)
        instance_2 = double('instance 2', :id => 2)

        context[:results] << raw_result(2, article_name)
        context[:results] << raw_result(1, article_name)

        article_model.stub(:order => article_model, :where => [instance_1, instance_2])
        search.options[:sql] = {:order => 'name DESC'}

        middleware.call [context]

        context[:results].should == [instance_1, instance_2]
      end

      it "handles model without primary key" do
        no_primary_key_model = double('no primary key model')
        active_record_base.stub(:descendants => [no_primary_key_model])
        no_primary_key_model.stub(:unscoped => no_primary_key_model)
        model_name = double('article', :constantize => no_primary_key_model)
        no_primary_key_model.stub(:name => model_name)
        instance   = double('instance', :id => 1)
        no_primary_key_model.stub :where => [instance]

        context[:results] << raw_result(1, model_name)

        middleware.call [context]
      end

      context 'SQL options' do
        let(:relation) { double('relation', :where => []) }

        before :each do
          article_model.stub :unscoped => relation

          context[:results] << raw_result(1, article_name)
        end

        it "passes through SQL include options to the relation" do
          search.options[:sql] = {:include => :association}

          relation.should_receive(:includes).with(:association).
            and_return(relation)

          middleware.call [context]
        end

        it "passes through SQL join options to the relation" do
          search.options[:sql] = {:joins => :association}

          relation.should_receive(:joins).with(:association).and_return(relation)

          middleware.call [context]
        end

        it "passes through SQL order options to the relation" do
          search.options[:sql] = {:order => 'name DESC'}

          relation.should_receive(:order).with('name DESC').and_return(relation)

          middleware.call [context]
        end

        it "passes through SQL select options to the relation" do
          search.options[:sql] = {:select => :column}

          relation.should_receive(:select).with(:column).and_return(relation)

          middleware.call [context]
        end

        it "passes through SQL group options to the relation" do
          search.options[:sql] = {:group => :column}

          relation.should_receive(:group).with(:column).and_return(relation)

          middleware.call [context]
        end
      end
    end
  end
end
