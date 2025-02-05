defmodule ExCucumber do
  @moduledoc ExCucumber.DocumentationResources.full_description_this_library()

  @external_resource "config/config.exs"

  alias CucumberExpressions.ParameterType
  use ExDebugger.Manual

  defmacro __using__(_) do
    quote location: :keep do
      import ExUnit.Assertions

      require ExCucumber.Gherkin.Keywords.Given
      require ExCucumber.Gherkin.Keywords.When
      require ExCucumber.Gherkin.Keywords.And
      require ExCucumber.Gherkin.Keywords.But
      require ExCucumber.Gherkin.Keywords.Then
      require ExCucumber.Gherkin.Keywords.Background
      require ExCucumber.Gherkin.Keywords.Scenario
      require ExCucumber.Gherkin.Keywords.Rule

      alias ExCucumber.Gherkin.Keywords, as: GherkinKeywords

      alias GherkinKeywords.{
        Given,
        When,
        And,
        But,
        Then,
        Background,
        Scenario,
        Rule
      }

      import unquote(__MODULE__)

      Module.register_attribute(__MODULE__, :cucumber_expressions, accumulate: true)
      Module.register_attribute(__MODULE__, :meta, accumulate: false)
      Module.register_attribute(__MODULE__, :feature, accumulate: false)
      Module.register_attribute(__MODULE__, :custom_param_types, accumulate: false)

      Module.register_attribute(__MODULE__, :context_nesting, accumulate: true)

      Module.put_attribute(__MODULE__, :meta, %{})
      Module.put_attribute(__MODULE__, :custom_param_types, [])

      @before_compile unquote(__MODULE__)
      @after_compile unquote(__MODULE__)
    end
  end

  defmacro __before_compile__(_) do
    quote location: :keep do
      @cucumber_expressions_parse_tree ExCucumber.CucumberExpression.parse(@cucumber_expressions)

      alias ExCucumber.Gherkin.Traverser.Ctx
      alias ExCucumber.Gherkin.Keywords, as: GherkinKeywords

      def execute_mfa(%Ctx{} = ctx, args) do
        actual_gherkin_token_as_parsed_from_feature_file = ctx.token

        {fun, {def_meta, _}} =
          if ExCucumber.Config.best_practices().enforce_context? do
            ctx.extra.fun
            |> List.wrap()
            |> Enum.filter(fn fun ->
              {def_meta, context_nesting} = @meta[fun]

              ctx.extra.context_history
              |> Enum.map(&{&1.name, &1.title || :no_title})
              |> Kernel.==(context_nesting)
            end)
            |> case do
              [] ->
                raise "No matches found: #{
                        inspect([ids: ctx.extra.fun, meta: @meta], pretty: true, limit: :infinity)
                      }"

              [e] ->
                {e, @meta[e]}

              multiple_matches_ambiguity ->
                multiple_matches_ambiguity
                |> Enum.filter(fn e ->
                  elem(@meta[e], 0).macro_usage_gherkin_keyword ==
                    actual_gherkin_token_as_parsed_from_feature_file
                end)
                |> case do
                  [] ->
                    raise "No matches found: #{
                            inspect([ids: ctx.extra.fun, meta: @meta],
                              pretty: true,
                              limit: :infinity
                            )
                          }"

                  [e] ->
                    {e, @meta[e]}

                  multiple_matches_ambiguity ->
                    raise "Multiple matches found: #{
                            inspect(
                              [
                                multiple_matches_ambiguity: multiple_matches_ambiguity,
                                extra: ctx.extra,
                                meta: @meta
                              ],
                              pretty: true,
                              limit: :infinity
                            )
                          }"
                end
            end
          else
            fun =
              ctx.extra.fun
              |> List.wrap()
              |> Enum.at(0)

            {fun, @meta[fun]}
          end

        gherkin_token_mismatch? =
          actual_gherkin_token_as_parsed_from_feature_file != def_meta.macro_usage_gherkin_keyword

        arg =
          if def_meta.has_arg? do
            [args]
          else
            []
          end

        # dd({arg, @meta, ctx}, :execute_mfa)

        if ExCucumber.Config.best_practices().disallow_gherkin_token_usage_mismatch? &&
            gherkin_token_mismatch? do
          ExCucumber.Exceptions.UsageError.raise(
            Ctx.extra(ctx, %{
              def_line: def_meta.line,
              wrong_token: def_meta.macro_usage_gherkin_keyword
            }),
            :gherkin_token_mismatch
          )
        else
          try do
            result = apply(__MODULE__, fun, arg)
            IO.write("#{IO.ANSI.green()}.#{IO.ANSI.reset()}")
            {result, def_meta}
          rescue
            e in [ExUnit.AssertionError] ->
              ExCucumber.Exceptions.StepError.raise(
                Ctx.extra(ctx, %{
                  def_meta: def_meta,
                  raised_error: e
                }),
                :error_raised
              )

            e ->
              # This is easier but not sure it applies to all stack traces
              # __STACKTRACE__
              # |> Enum.chunk_by(fn
              #   {_, :execute_mfa, 2, _} -> :pivot
              #   e -> :default
              # end)

              # This one is more complicated but should work always
              {left, right} = __STACKTRACE__
                |> Enum.reduce({:append_to_left, {[], []}}, fn
                  e = {_, :execute_mfa, 2, _}, {_, {left, right}} -> {:append_to_right, {left, [right | [e]]}}
                  e , {state, {left, right}} -> {left, right} = state
                    |> case do
                      :append_to_left -> {[left | [e]], right}
                      :append_to_right -> {left, [right | [e]]}
                    end
                    {state, {left, right}}
                end)
                |> elem(1)

              f = args.feature_file
              middle = [
                {def_meta.cucumber_expression.meta.module, def_meta.cucumber_expression.meta.gherkin_keyword, [def_meta.cucumber_expression.formulation], [file: def_meta.cucumber_expression.meta.file, line: def_meta.cucumber_expression.meta.line_nr]},
                {:feature_file, :line, [f.text], [file: ExCucumber.Config.feature_path(@feature), line: f.location.line]}
              ]
              s = List.flatten([left, middle, right])
              reraise e, s
          end
        end
      end
    end
  end

  defmacro __after_compile__(env, _) do
    quote location: :keep do
      custom_param_types = ExCucumber.CustomParameterType.Loader.run(@custom_param_types)
      @feature
      |> ExCucumber.Config.feature_path()
      |> ExCucumber.Gherkin.run(
        __MODULE__,
        unquote(Macro.escape(env)).file,
        @cucumber_expressions_parse_tree,
        custom_param_types,
        Application.get_env(:ex_cucumber, :line),
        false
      )
    end
  end


  :context_macros
  |> ExCucumber.Gherkin.Keywords.mappings()
  |> Map.fetch!(:regular)
  |> Enum.each(fn macro_name ->
    @doc false
    defmacro unquote(macro_name)(do: block) do
      ExCucumber.define_context_macro(
        __CALLER__,
        unquote(macro_name),
        :no_title,
        nil,
        block
      )
    end

    @doc false
    defmacro unquote(macro_name)(title, do: block) do
      ExCucumber.define_context_macro(
        __CALLER__,
        unquote(macro_name),
        title,
        nil,
        block
      )
    end
  end)

  :def_based_gwt_macros
  |> ExCucumber.Gherkin.Keywords.mappings()
  |> Enum.each(fn {gherkin_keyword, macro_name} ->
    if ExCucumber.Gherkin.Keywords.macro_style?(:def) do
      @doc false
      defmacro unquote(macro_name)(cucumber_expression, arg, do: block) do
        ExCucumber.define_gherkin_keyword_macro(
          __CALLER__,
          unquote(gherkin_keyword),
          cucumber_expression,
          [arg],
          block
        )
      end

      @doc false
      defmacro unquote(macro_name)(cucumber_expression, do: block) do
        ExCucumber.define_gherkin_keyword_macro(
          __CALLER__,
          unquote(gherkin_keyword),
          cucumber_expression,
          nil,
          block
        )
      end
    else
      @doc false
      defmacro unquote(macro_name)(cucumber_expression, _arg, _) do
        ExCucumber.define_gherkin_keyword_mismatch_macro(
          __CALLER__,
          unquote(gherkin_keyword),
          cucumber_expression
        )
      end

      @doc false
      defmacro unquote(macro_name)(cucumber_expression, _arg) do
        ExCucumber.define_gherkin_keyword_mismatch_macro(
          __CALLER__,
          unquote(gherkin_keyword),
          cucumber_expression
        )
      end
    end
  end)

  @doc false
  def define_context_macro(
        caller = %Macro.Env{},
        macro_name,
        title,
        arg,
        block
      ) do
    _line = caller.line
    has_arg? = arg != nil

    ast =
      if has_arg? do
        raise "Not implemented yet."
      else
        quote do
          @context_nesting {unquote(macro_name), unquote(title)}

          unquote(block)

          context_nesting = tl(@context_nesting)
          Module.delete_attribute(__MODULE__, :context_nesting)
          Module.register_attribute(__MODULE__, :context_nesting, accumulate: true)

          context_nesting
          |> Enum.reverse()
          |> Enum.each(fn scenario ->
            @context_nesting scenario
          end)
        end
      end

    ast
  end

  @doc false
  def define_gherkin_keyword_macro(
        caller = %Macro.Env{},
        gherkin_keyword,
        cucumber_expression,
        arg,
        block
      ) do
    line = caller.line

    cucumber_expression =
      ExCucumber.CucumberExpression.new(cucumber_expression, caller, gherkin_keyword)

    func = cucumber_expression.meta.id
    has_arg? = arg != nil

    module_attrs_ast =
      quote bind_quoted: [
              cucumber_expression: Macro.escape(cucumber_expression),
              func: func,
              meta:
                Macro.escape(%{
                  has_arg?: has_arg?,
                  line: line,
                  macro_usage_gherkin_keyword: gherkin_keyword,
                  cucumber_expression: cucumber_expression
                })
            ] do
        @cucumber_expressions cucumber_expression
        @meta Map.put(@meta, func, {meta, @context_nesting})
        @meta Map.put(@meta, cucumber_expression.formulation, func)
      end

    def_ast =
      if has_arg? do
        quote do
          @doc false
          def unquote(func)(unquote_splicing(arg)), do: unquote(block)
        end
      else
        quote do
          @doc false
          def unquote(func)(), do: unquote(block)
        end
      end

    [module_attrs_ast, def_ast]
  end

  @doc false
  def define_gherkin_keyword_mismatch_macro(
        caller = %Macro.Env{},
        gherkin_keyword,
        cucumber_expression
      ) do
    quote bind_quoted: [
            caller: Macro.escape(caller),
            cucumber_expression: cucumber_expression,
            gherkin_keyword: gherkin_keyword
          ] do
      ctx =
        @feature
        |> ExCucumber.Config.feature_path()
        |> ExCucumber.Gherkin.Traverser.Ctx.new(
          caller.module,
          caller.file,
          ParameterType.new(),
          %{column: 0, line: caller.line},
          "",
          gherkin_keyword
        )
        |> ExCucumber.Gherkin.Traverser.Ctx.extra(%{cucumber_expression: cucumber_expression})

      ExCucumber.Exceptions.ConfigurationError.raise(ctx, :macro_style_mismatch)
    end
  end
end
