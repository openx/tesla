defmodule Tesla.Builder do
  @http_verbs ~w(head get delete trace options post put patch)a
  @body ~w(post put patch)a

  defmacro __using__(opts \\ []) do
    opts = Macro.prewalk(opts, &Macro.expand(&1, __CALLER__))
    docs = Keyword.get(opts, :docs, true)

    quote do
      Module.register_attribute(__MODULE__, :__middleware__, accumulate: true)
      Module.register_attribute(__MODULE__, :__adapter__, [])

      if unquote(docs) do
        @type option ::
                {:method, Tesla.Env.method()}
                | {:url, Tesla.Env.url()}
                | {:query, Tesla.Env.query()}
                | {:headers, Tesla.Env.headers()}
                | {:body, Tesla.Env.body()}
                | {:opts, Tesla.Env.opts()}

        @doc """
        Perform a request using client function

        Options:
        - `:method`   - the request method, one of [:head, :get, :delete, :trace, :options, :post, :put, :patch]
        - `:url`      - either full url e.g. "http://example.com/some/path" or just "/some/path" if using `Tesla.Middleware.BaseUrl`
        - `:query`    - a keyword list of query params, e.g. `[page: 1, per_page: 100]`
        - `:headers`  - a keyworld list of headers, e.g. `[{"content-type", "text/plain"}]`
        - `:body`     - depends on used middleware:
            - by default it can be a binary
            - if using e.g. JSON encoding middleware it can be a nested map
            - if adapter supports it it can be a Stream with any of the above
        - `:opts`     - custom, per-request middleware or adapter options

        Examples:

            ExampleApi.request(method: :get, url: "/users/path")

        You can also use shortcut methods like:

            ExampleApi.get("/users/1")

        or

            myclient |> ExampleApi.post("/users", %{name: "Jon"})
        """
        @spec request(Tesla.Env.client(), [option]) :: Tesla.Env.result()
      else
        @doc false
      end

      def request(%Tesla.Client{} = client \\ %Tesla.Client{}, options) do
        Tesla.execute(__MODULE__, client, options)
      end

      def request!(%Tesla.Client{} = client \\ %Tesla.Client{}, options) do
        Tesla.execute!(__MODULE__, client, options)
      end

      unquote(generate_http_verbs(opts))

      import Tesla.Builder, only: [plug: 1, plug: 2, adapter: 1, adapter: 2]
      @before_compile Tesla.Builder
    end
  end

  @doc """
  Attach middleware to your API client

  ```ex
  defmodule ExampleApi do
    use Tesla

    # plug middleware module with options
    plug Tesla.Middleware.BaseUrl, "http://api.example.com"

    # or without options
    plug Tesla.Middleware.JSON

    # or a custom middleware
    plug MyProject.CustomMiddleware
  end
  """

  defmacro plug(middleware, opts) do
    quote do
      @__middleware__ {
        {unquote(Macro.escape(middleware)), unquote(Macro.escape(opts))},
        {:middleware, unquote(Macro.escape(__CALLER__))}
      }
    end
  end

  defmacro plug(middleware) do
    quote do
      @__middleware__ {
        unquote(Macro.escape(middleware)),
        {:middleware, unquote(Macro.escape(__CALLER__))}
      }
    end
  end

  @doc """
  Choose adapter for your API client

  ```ex
  defmodule ExampleApi do
    use Tesla

    # set adapter as module
    adapter Tesla.Adapter.Hackney

    # set adapter as anonymous function
    adapter fn env ->
      ...
      env
    end
  end
  """
  defmacro adapter(name, opts) do
    quote do
      @__adapter__ {
        {unquote(Macro.escape(name)), unquote(Macro.escape(opts))},
        {:adapter, unquote(Macro.escape(__CALLER__))}
      }
    end
  end

  defmacro adapter(name) do
    quote do
      @__adapter__ {
        unquote(Macro.escape(name)),
        {:adapter, unquote(Macro.escape(__CALLER__))}
      }
    end
  end

  defmacro __before_compile__(env) do
    Tesla.Migration.breaking_alias_in_config!(env.module)

    adapter =
      env.module
      |> Module.get_attribute(:__adapter__)
      |> compile()

    middleware =
      env.module
      |> Module.get_attribute(:__middleware__)
      |> Enum.reverse()
      |> compile()

    quote location: :keep do
      def __middleware__, do: unquote(middleware)
      def __adapter__, do: unquote(adapter)
    end
  end

  def client(pre, post), do: %Tesla.Client{pre: runtime(pre), post: runtime(post)}

  @default_opts []

  defp compile(nil), do: nil
  defp compile(list) when is_list(list), do: Enum.map(list, &compile/1)

  # {Tesla.Middleware.Something, opts}
  defp compile({{{:__aliases__, _, _} = ast_mod, ast_opts}, {_kind, caller}}) do
    Tesla.Migration.breaking_headers_map!(ast_mod, ast_opts, caller)
    quote do: {unquote(ast_mod), :call, [unquote(ast_opts)]}
  end

  # :local_middleware, opts
  defp compile({{name, _opts}, {kind, caller}}) when is_atom(name) do
    Tesla.Migration.breaking_alias!(kind, name, caller)
  end

  # Tesla.Middleware.Something
  defp compile({{:__aliases__, _, _} = ast_mod, {_kind, _caller}}) do
    quote do: {unquote(ast_mod), :call, [unquote(@default_opts)]}
  end

  # fn env -> ... end
  defp compile({{:fn, _, _} = ast_fun, {_kind, _caller}}) do
    quote do: {:fn, unquote(ast_fun)}
  end

  # :local_middleware
  defp compile({name, {kind, caller}}) when is_atom(name) do
    Tesla.Migration.breaking_alias!(kind, name, caller)
  end

  defp runtime(list) when is_list(list), do: Enum.map(list, &runtime/1)
  defp runtime({module, opts}) when is_atom(module), do: {module, :call, [opts]}
  defp runtime(fun) when is_function(fun), do: {:fn, fun}
  defp runtime(module) when is_atom(module), do: {module, :call, [@default_opts]}

  defp generate_http_verbs(opts) do
    only = Keyword.get(opts, :only, @http_verbs)
    except = Keyword.get(opts, :except, [])
    docs = Keyword.get(opts, :docs, true)

    for method <- @http_verbs do
      for bang <- [:safe, :bang],
          client <- [:client, :noclient],
          opts <- [:opts, :noopts],
          method in only && method not in except do
        gen(method, bang, client, opts, docs)
      end
    end
  end

  defp gen(method, safe, client, opts, docs) do
    quote location: :keep do
      unquote(gen_doc(method, safe, client, opts, docs))
      unquote(gen_fun(method, safe, client, opts))
      unquote(gen_deprecated(method, safe, client, opts))
    end
  end

  defp gen_doc(method, safe, :client, :opts, true) do
    request = to_string(req(safe))
    name = name(method, safe)
    body = if method in @body, do: ~s|, %{name: "Jon"}|, else: ""

    quote location: :keep do
      @doc """
      Perform a #{unquote(method |> to_string |> String.upcase())} request.
      See `#{unquote(request)}/1` or `#{unquote(request)}/2` for options definition.

          #{unquote(name)}("/users"#{unquote(body)})
          #{unquote(name)}("/users"#{unquote(body)}, query: [scope: "admin"])
          #{unquote(name)}(client, "/users"#{unquote(body)})
          #{unquote(name)}(client, "/users"#{unquote(body)}, query: [scope: "admin"])
      """
      @spec unquote(name)(unquote_splicing(input_types(method, :client, :opts))) ::
              unquote(output_type(safe))
    end
  end

  defp gen_doc(method, safe, client, opts, true) do
    name = name(method, safe)

    quote location: :keep do
      @doc false
      @spec unquote(name)(unquote_splicing(input_types(method, client, opts))) ::
              unquote(output_type(safe))
    end
  end

  defp gen_doc(_method, _bang, _client, _opts, false) do
    quote location: :keep do
      @doc false
    end
  end

  defp input_types(method, client, opts) do
    type(client) ++ type(:url) ++ type(method) ++ type(opts)
  end

  defp type(:client), do: [quote(do: Tesla.Env.client())]
  defp type(:noclient), do: []
  defp type(:opts), do: [quote(do: [option])]
  defp type(:noopts), do: []
  defp type(:url), do: [quote(do: Tesla.Env.url())]
  defp type(method) when method in @body, do: [quote(do: Tesla.Env.body())]
  defp type(_method), do: []

  defp output_type(:safe), do: quote(do: Tesla.Env.result())
  defp output_type(:bang), do: quote(do: Tesla.Env.t() | no_return)

  defp gen_fun(method, safe, client, opts) do
    quote location: :keep do
      def unquote(name(method, safe))(unquote_splicing(inputs(method, client, opts))) do
        unquote(req(safe))(unquote_splicing(outputs(method, client, opts)))
      end
    end
    |> gen_guards(opts)
  end

  defp gen_guards({:def, _, [head, [do: body]]}, :opts) do
    quote do
      def unquote(head) when is_list(opts), do: unquote(body)
    end
  end

  defp gen_guards(def, _opts), do: def

  defp gen_deprecated(method, safe, :client, opts) do
    inputs = [quote(do: client) | inputs(method, :noclient, opts)]

    quote location: :keep do
      def unquote(name(method, safe))(unquote_splicing(inputs)) when is_function(client) do
        Tesla.Migration.client_function!()
      end
    end
  end

  defp gen_deprecated(_method, _safe, _, _opts), do: nil

  defp name(method, :safe), do: method
  defp name(method, :bang), do: String.to_atom("#{method}!")

  defp req(:safe), do: :request
  defp req(:bang), do: :request!

  defp inputs(method, client, opts) do
    input(client) ++ input(:url) ++ input(method) ++ input(opts)
  end

  defp input(:client), do: [quote(do: %Tesla.Client{} = client)]
  defp input(:noclient), do: []
  defp input(:opts), do: [quote(do: opts)]
  defp input(:noopts), do: []
  defp input(:url), do: [quote(do: url)]
  defp input(method) when method in @body, do: [quote(do: body)]
  defp input(_method), do: []

  defp outputs(method, client, opts), do: output(client) ++ [output(output(method), opts)]
  defp output(:client), do: [quote(do: client)]
  defp output(:noclient), do: []
  defp output(m) when m in @body, do: quote(do: [method: unquote(m), url: url, body: body])
  defp output(m), do: quote(do: [method: unquote(m), url: url])
  defp output(prev, :opts), do: quote(do: unquote(prev) ++ opts)
  defp output(prev, :noopts), do: prev
end
