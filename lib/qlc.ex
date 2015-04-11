defmodule Qlc do
  defmodule Cursor do
    defstruct c: nil
  end
  @type bindings :: [any]
  @type query_cursor :: Qlc.Cursor
  @type expr :: any
  @type qlc_opt :: record(:qlc_opt)
  @type qlc_handle :: record(:qlc_handle)
  @type qlc_lc :: record(:qlc_lc)

  require Record
  @qlc_handle_fields Record.extract(:qlc_handle, 
                                       from_lib: "stdlib/src/qlc.erl") 
  Record.defrecord :qlc_handle, @qlc_handle_fields
  @qlc_opt_fields Record.extract(:qlc_opt, from_lib: "stdlib/src/qlc.erl")
  Record.defrecord :qlc_opt, @qlc_opt_fields
  @qlc_lc_fields Record.extract(:qlc_lc, from_lib: "stdlib/src/qlc.erl")
  Record.defrecord :qlc_lc, @qlc_lc_fields

  @doc """
  string to erlang ast
  """
  @spec exprs(String.t) :: expr
  def exprs(s) do
    c = String.to_char_list(s)
    {:ok, m, _} = :erl_scan.string(c)
    {:ok, [expr]} = :erl_parse.parse_exprs(m)
    expr
  end
  @doc """
  optoin list to record(:qlc_opt)
  """
  @spec options(list, list, qlc_opt) :: qlc_opt
  def options(_opt, [], acc) do 
    acc
  end
  @spec options(list, list, qlc_opt) :: qlc_opt
  def options(opt, [k|l], acc) do
    acc = case Keyword.get(opt, k, nil) do
            nil -> if  Enum.member?(opt, k) do
                     case k do
                       :unique -> qlc_opt(acc, unique: true)
                       :cache -> qlc_opt(acc, cache: true)
                     end
                   else
                     acc
                   end
            r ->
              case k do 
                :max_lookup -> qlc_opt(acc, max_lookup: r)
                :cache -> qlc_opt(acc, cache: r)
                :join -> qlc_opt(acc, join: r)
                :unique -> qlc_opt(acc, unique: r)
              end
          end
    options(opt, l, acc)
  end
  @doc """
  erlang ast with binding variables to qlc_handle
  """
  def expr_to_handle(expr, bind, opt) do
    {:ok, {:call, _, _q, handle}} = :qlc_pt.transform_expression(expr, bind)
    {:value, q, _} = :erl_eval.exprs(handle, bind)
    optkeys = [:max_lookup,:cache, :join,:lookup,:unique]
    opt_r = options(opt, optkeys, qlc_opt())
    qlc_handle(h: qlc_lc(q, opt: opt_r))
  end
  @doc """
  variable binding list to erlang_binding list
  """
  @spec bind([], bindings) :: bindings
  def bind([], b) do 
    b
  end
  @spec bind([Keyword], bindings) :: bindings
  def bind([{k, v} | t], b) when is_atom(k) do
    bind(t, :erl_eval.add_binding(k, v, b))
  end
  @spec bind([Keyword]) :: bindings
  def bind(a) when is_list(a) do
    bind(a, :erl_eval.new_binding())
  end
  @doc """
  string to qlc_handle with variable bindings
  """
  @spec string_to_handle(String.t, bindings, list) :: qlc_handle
  def string_to_handle(s, bindings, opt \\ []) when is_binary(s) do
    :qlc.string_to_handle(String.to_char_list(s), bindings, opt)
  end
  @doc """
  string to qlc_handle with variable bindings
  (string must be literal, because its a macro.)

  qlc expression string
  
  ## syntax

      [Expression || Qualifier1, Qualifier2, ...]

      Expression :: arbitary Erlang term (the template)

      Qualifier :: Filter or Generators

      Fiilter :: Erlang expressions returning bool()

      Generator :: Pattern <- ListExpression

      ListExpression :: Qlc_handle or list()

      Qlc_handle :: returned from Qlc.table/2, Qlc.sort/2, Qlc.keysort/2
                                Qlc.q/2, Qlc.string_to_handle/2
  ## example
 
      iex> require Qlc
      iex> list = [a: 1,b: 2,c: 3]
      iex> qlc_handle = Qlc.q("[X || X = {K,V} <- L, K =/= Item]", 
      ...>        [L: list, Item: :b])
      ...> Qlc.e(qlc_handle)
      [a: 1, c: 3]
      ...> Qlc.q("[X || X = {K, V} <- L, K =:= Item]",
      ...>       [L: qlc_handle, Item: :c]) |>
      ...> Qlc.e
      [c: 3]

  """
  @spec q(String.t, bindings, list) :: qlc_handle
  defmacro q(string, bindings, opt \\ []) when is_binary(string) do
    string = case String.last(string) do
               "." -> string
               _ -> string <> "."
             end
    expr = exprs(string)
    exprl = Macro.escape(expr)
    quote bind_quoted: [exprl: exprl, bindings: bindings, opt: opt] do
      Qlc.expr_to_handle(exprl, bindings, opt)
    end
  end
  @doc """
  eval qlc_handle
  """
  @spec e(qlc_handle) :: list
  def e(qh) do
    :qlc.e(qh)
  end
  @doc """
  fold qlc_handle with accumulator
  
  ## example
      iex> require Qlc
      iex> list = [a: 1,b: 2,c: 3]
      iex> qlc_handle = Qlc.q("[X || X = {K,V} <- L, K =/= Item]", 
      ...>        [L: list, Item: :b])
      ...> Qlc.fold(qlc_handle, [], fn({k,v}, acc) -> 
      ...>   [{v, k}|acc]
      ...> end)
      [{3, :c}, {1, :a}]
   """
  @spec fold(qlc_handle, any, (any, any -> any), [any]) :: any
  def fold(qh, a, f, option \\ []) do
    :qlc.fold(f, a, qh, option)
  end
  @doc """
  create qlc cursor from qlc_handle
  (create processes)
  """
  @spec cursor(qlc_handle) :: query_cursor
  def cursor(qh) do
    %Qlc.Cursor{c: :qlc.cursor(qh)}
  end
  @doc """
  delete qlc cursor
  (kill processes)
  """
  @spec delete_cursor(Qlc.Cursor) :: :ok
  def delete_cursor(qc) do
    :qlc.delete_cursor(qc.c)
  end
end
defimpl Enumerable, for: Qlc.Cursor do
  def count(_qc) do
    {:error, __MODULE__}
  end
  def member?(_qc,_) do
    {:error, __MODULE__}
  end
  def reduce(qc, {:halt, acc}, _fun) do
    Qlc.delete_cursor(qc)
    {:halted, acc}
  end
  def reduce(qc, {:suspend, acc}, fun) do
    {:suspended, acc, fn(x) -> reduce(qc, x, fun) end}
  end
  def reduce(qc, {:cont, acc}, fun) do
    case :qlc.next_answers(qc.c, 1) do
      [] -> 
        Qlc.delete_cursor(qc)
        {:done, acc}
      [h] -> 
        reduce(qc, fun.(h, acc), fun)
    end
  end
end