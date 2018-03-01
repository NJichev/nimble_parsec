# TODO: map at runtime
# TODO: runtime_composition()
# TODO: integer()
# TODO: many()
# TODO: choice()
# TODO: Docs

defmodule NimbleParsec do
  defmacrop is_combinator(combinator) do
    quote do
      is_list(unquote(combinator))
    end
  end

  defmacro defparsec(name, combinator, opts \\ []) do
    quote bind_quoted: [name: name, combinator: combinator, opts: opts] do
      def unquote(name)(binary, opts \\ []) when is_binary(binary) do
        unquote(:"#{name}__0")(binary, [], 1, 1)
      end

      for {name, args, guards, body} <- NimbleParsec.Compiler.compile(name, combinator, opts) do
        defp unquote(name)(unquote_splicing(args)) when unquote(guards), do: unquote(body)

        # IO.puts(Macro.to_string(quote do
        #   defp unquote(name)(unquote_splicing(args)) when unquote(guards), do: unquote(body)
        # end))
      end
    end
  end

  # Steps to add a new bound combinator:
  #
  #   1. Update the combinator type
  #   2. Update the compiler bound combinator step
  #   3. Update the compiler label step
  #
  @type t :: [combinator()]
  @type bit_modifiers :: [:signed | :unsigned | :native | :little | :big]

  @typep combinator ::
           {:literal, binary}
           | {:label, t, binary}
           | {:compile_bit_integer, [Range.t()], bit_modifiers}
           | {:compile_map, t, (Macro.t() -> Macro.t()), (term -> term)}

  @doc ~S"""
  Returns an empty combinator.

  An empty combinator cannot be compiled on its own.
  """
  def empty() do
    []
  end

  @doc ~S"""
  Defines a single ascii codepoint in the given ranges.

  ## Examples

      defmodule MyParser do
        import NimbleParsec

        defparsec :digit_and_lowercase,
                  empty()
                  |> ascii_codepoint([?0..?9])
                  |> ascii_codepoint([?a..?z])
      end

      MyParser.digit_and_lowercase("1a")
      #=> {:ok, [?1, ?a], "", 1, 3}

      MyParser.digit_and_lowercase("a1")
      #=> {:error, "expected a byte in the range ?0..?9, followed by a byte in the range ?a..?z", "a1", 1, 1}

  """
  def ascii_codepoint(combinator \\ empty(), ranges) do
    if ranges == [] or Enum.any?(ranges, &(?\n in &1)) do
      # TODO: Implement this.
      raise ArgumentError,
            "empty ranges or ranges with newlines in them are not currently supported"
    else
      compile_bit_integer(combinator, ranges, [])
    end
  end

  @doc ~S"""
  Adds a label to the combinator to be used in error reports.

  ## Examples

      defmodule MyParser do
        import NimbleParsec

        defparsec :digit_and_lowercase,
                  empty()
                  |> ascii_codepoint([?0..?9])
                  |> ascii_codepoint([?a..?z])
                  |> label("a digit followed by lowercase letter")
      end

      MyParser.digit_and_lowercase("1a")
      #=> {:ok, [?1, ?a], "", 1, 3}

      MyParser.digit_and_lowercase("a1")
      #=> {:error, "expected a digit followed by lowercase letter", "a1", 1, 1}

  """
  def label(combinator \\ empty(), to_label, label)
      when is_combinator(combinator) and is_combinator(to_label) and is_binary(label) do
    to_label = reverse_combinators!(to_label, "label")
    [{:label, to_label, label} | combinator]
  end

  @doc ~S"""
  Defines an integer combinator with `min` and `max` length.

  ## Examples

      defmodule MyParser do
        import NimbleParsec

        defparsec :two_digits_integer, integer(2, 2)
      end

      MyParser.two_digits_integer("123")
      #=> {:ok, [12], "3", 1, 3}

      MyParser.two_digits_integer("1a3")
      #=> {:error, "expected a two digits integer", "1a3", 1, 1}

  """
  def integer(combinator \\ empty(), min, max)

  def integer(combinator, size, size)
      when is_integer(size) and size > 0 and is_combinator(combinator) do
    integer =
      Enum.reduce(1..size, empty(), fn _, acc ->
        compile_bit_integer(acc, [?0..?9], [])
      end)

    mapped = compile_map(empty(), integer, &from_ascii_to_integer/1)
    label(combinator, mapped, "a #{size} digits integer")
  end

  def integer(combinator, min, max)
      when is_integer(min) and min > 0 and is_integer(max) and max >= min and
             is_combinator(combinator) do
    # TODO: Implement variadic size integer.
    raise ArgumentError, "not yet implemented"
  end

  defp from_ascii_to_integer(vars) do
    vars
    |> from_ascii_to_integer(1)
    |> Enum.reduce(&{:+, [], [&2, &1]})
    |> List.wrap()
  end

  defp from_ascii_to_integer([var | vars], index) do
    [quote(do: (unquote(var) - ?0) * unquote(index)) | from_ascii_to_integer(vars, index * 10)]
  end

  defp from_ascii_to_integer([], _index) do
    []
  end

  @doc ~S"""
  Defines a literal binary value.

  ## Examples

      defmodule MyParser do
        import NimbleParsec

        defparsec :literal_t, literal("T")
      end

      MyParser.literal_t("T")
      #=> {:ok, ["T"], "", 1, 2}

      MyParser.literal_t("not T")
      #=> {:error, "expected a literal \"T\"", "not T", 1, 1}

  """
  def literal(combinator \\ empty(), binary)
      when is_combinator(combinator) and is_binary(binary) do
    [{:literal, binary} | combinator]
  end

  @doc """
  Ignores the output of combinator given in `to_ignore`.

  ## Examples

      defmodule MyParser do
        import NimbleParsec

        defparsec :ignorable, literal("T") |> ignore() |> integer(2, 2)
      end

      MyParser.ignorable("T12")
      #=> {:ok, [12], "", 1, 3}

  """
  def ignore(combinator \\ empty(), to_ignore)

  def ignore(combinator, to_ignore) when is_combinator(combinator) and is_combinator(to_ignore) do
    to_ignore = reverse_combinators!(to_ignore, "ignore")
    # TODO: Define the runtime behaviour.
    compile_map(combinator, to_ignore, fn _ -> [] end)
  end

  # A compile map may or may not be expanded at runtime as
  # it depends if `to_map` is also bound. For this reason,
  # some operators may pass a runtime_fun/1. If one is not
  # passed, it is assumed that the behaviour is guaranteed
  # to be bound.
  #
  # Notice the `to_map` inside the document is already
  # expected to be reversed.
  defp compile_map(combinator, to_map, compile_fun, runtime_fun \\ &must_never_be_invoked/1) do
    [{:compile_map, to_map, compile_fun, runtime_fun} | combinator]
  end

  # A compile bit integer is verified to not have a newline on it
  # and is always bound.
  defp compile_bit_integer(combinator, [_ | _] = ranges, modifiers) do
    [{:compile_bit_integer, ranges, modifiers} | combinator]
  end

  defp reverse_combinators!([], action) do
    raise ArgumentError, "cannot #{action} empty combinator"
  end

  defp reverse_combinators!(combinators, _action) do
    Enum.reverse(combinators)
  end

  defp must_never_be_invoked(_) do
    raise "this function must never be invoked"
  end
end