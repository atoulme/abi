defmodule ABI.TypeEncoder do
  @moduledoc """
  `ABI.TypeEncoder` is responsible for encoding types to the format
  expected by Solidity. We generally take a function selector and an
  array of data and encode that array according to the specification.
  """

  @doc """
  Encodes the given data based on the function selector.

  ## Examples

      iex> [69, true]
      ...> |> ABI.TypeEncoder.encode(
      ...>      %ABI.FunctionSelector{
      ...>        function: "baz",
      ...>        types: [
      ...>          {:uint, 32},
      ...>          :bool
      ...>        ],
      ...>        returns: :bool
      ...>      }
      ...>    )
      ...> |> Base.encode16(case: :lower)
      "cdcd77c000000000000000000000000000000000000000000000000000000000000000450000000000000000000000000000000000000000000000000000000000000001"

      iex> ["hello world"]
      ...> |> ABI.TypeEncoder.encode(
      ...>      %ABI.FunctionSelector{
      ...>        function: nil,
      ...>        types: [
      ...>          :string,
      ...>        ]
      ...>      }
      ...>    )
      ...> |> Base.encode16(case: :lower)
      "000000000000000000000000000000000000000000000000000000000000000b00000000000000000000000000000000000000000068656c6c6f20776f726c64"

      iex> [{"awesome", true}]
      ...> |> ABI.TypeEncoder.encode(
      ...>      %ABI.FunctionSelector{
      ...>        function: nil,
      ...>        types: [
      ...>          {:tuple, [:string, :bool]}
      ...>        ]
      ...>      }
      ...>    )
      ...> |> Base.encode16(case: :lower)
      "00000000000000000000000000000000000000000000000000000000000000400000000000000000000000000000000000000000000000000000000000000001000000000000000000000000000000000000000000000000000000000000000700000000000000000000000000000000000000000000000000617765736f6d65"

      iex> [{17, true}]
      ...> |> ABI.TypeEncoder.encode(
      ...>      %ABI.FunctionSelector{
      ...>        function: nil,
      ...>        types: [
      ...>          {:tuple, [{:uint, 32}, :bool]}
      ...>        ]
      ...>      }
      ...>    )
      ...> |> Base.encode16(case: :lower)
      "00000000000000000000000000000000000000000000000000000000000000110000000000000000000000000000000000000000000000000000000000000001"

      iex> [[17, 1]]
      ...> |> ABI.TypeEncoder.encode(
      ...>      %ABI.FunctionSelector{
      ...>        function: "baz",
      ...>        types: [
      ...>          {:array, {:uint, 32}, 2}
      ...>        ]
      ...>      }
      ...>    )
      ...> |> Base.encode16(case: :lower)
      "3d0ec53300000000000000000000000000000000000000000000000000000000000000110000000000000000000000000000000000000000000000000000000000000001"

      iex> [[17, 1], true]
      ...> |> ABI.TypeEncoder.encode(
      ...>      %ABI.FunctionSelector{
      ...>        function: nil,
      ...>        types: [
      ...>          {:array, {:uint, 32}, 2},
      ...>          :bool
      ...>        ]
      ...>      }
      ...>    )
      ...> |> Base.encode16(case: :lower)
      "000000000000000000000000000000000000000000000000000000000000001100000000000000000000000000000000000000000000000000000000000000010000000000000000000000000000000000000000000000000000000000000001"

      iex> [[17, 1]]
      ...> |> ABI.TypeEncoder.encode(
      ...>      %ABI.FunctionSelector{
      ...>        function: nil,
      ...>        types: [
      ...>          {:array, {:uint, 32}}
      ...>        ]
      ...>      }
      ...>    )
      ...> |> Base.encode16(case: :lower)
      "000000000000000000000000000000000000000000000000000000000000000200000000000000000000000000000000000000000000000000000000000000110000000000000000000000000000000000000000000000000000000000000001"
  """
  def encode(data, function_selector) do
    encode_method_id(function_selector) <>
    do_encode(function_selector.types, data)
  end

  @spec encode_method_id(%ABI.FunctionSelector{}) :: binary()
  defp encode_method_id(%ABI.FunctionSelector{function: nil}), do: ""
  defp encode_method_id(function_selector) do
    # Encode selector e.g. "baz(uint32,bool)" and take keccak
    kec = function_selector
    |> ABI.FunctionSelector.encode()
    |> ExthCrypto.Hash.Keccak.kec()

    # Take first four bytes
    <<init::binary-size(4), _rest::binary>> = kec

    # That's our method id
    init
  end

  @spec do_encode([ABI.FunctionSelector.type], [any()]) :: binary()
  defp do_encode([], _), do: <<>>
  defp do_encode([type|remaining_types], data) do
    {encoded, remaining_data} = encode_type(type, data)

    encoded <> do_encode(remaining_types, remaining_data)
  end

  @spec encode_type(ABI.FunctionSelector.type, [any()]) :: {binary(), [any()]}
  defp encode_type({:uint, size}, [data|rest]) do
    {encode_uint(data, size), rest}
  end

  defp encode_type(:address, data), do: encode_type({:uint, 160}, data)

  defp encode_type(:bool, [data|rest]) do
    value = case data do
      true -> encode_uint(1, 8)
      false -> encode_uint(0, 8)
      _ -> raise "Invalid data for bool: #{data}"
    end

    {value, rest}
  end

  defp encode_type(:string, [data|rest]) do
    {encode_uint(byte_size(data), 256) <> encode_bytes(data), rest}
  end

  defp encode_type(:bytes, [data|rest]) do
    {encode_uint(byte_size(data), 256) <> encode_bytes(data), rest}
  end

  defp encode_type({:tuple, types}, [data|rest]) do
    {head, tail, []} = Enum.reduce(types, {<<>>, <<>>, data |> Tuple.to_list}, fn type, {head, tail, data} ->
      {el, rest} = encode_type(type, data)

      if ABI.FunctionSelector.is_dynamic?(type) do
        # If we're a dynamic type, just encoded the length to head and the element to body
        {head <> encode_uint(byte_size(el), 256), tail <> el, rest}
      else
        # If we're a static type, simply encode the el to the head
        {head <> el, tail, rest}
      end
    end)

    {head <> tail, rest}
  end

  defp encode_type({:array, type, element_count}, [data | rest]) do
    repeated_type = Enum.map(1..element_count, fn _ -> type end)

    encode_type({:tuple, repeated_type}, [data |> List.to_tuple | rest])
  end

  defp encode_type({:array, type}, [data|_rest]=all_data) do
    element_count = Enum.count(data)

    encoded_uint = encode_uint(element_count, 256)
    {encoded_array, rest} = encode_type({:array, type, element_count}, all_data)

    {encoded_uint <> encoded_array, rest}
  end

  defp encode_type(els, _) do
    raise "Unsupported encoding type: #{inspect els}"
  end

  def encode_bytes(bytes) do
    bytes |> left_pad(byte_size(bytes))
  end

  # Note, we'll accept a binary or an integer here, so long as the
  # binary is not longer than our allowed data size
  defp encode_uint(data, size_in_bits) when rem(size_in_bits, 8) == 0 do
    size_in_bytes = ( size_in_bits / 8 ) |> round
    bin = maybe_encode_unsigned(data)

    if byte_size(bin) > size_in_bytes, do: raise "Data overflow encoding uint, data `#{data}` cannot fit in #{size_in_bytes * 8} bits"

    bin |> left_pad(size_in_bytes)
  end

  defp left_pad(bin, size_in_bytes) do
    # TODO: Create `left_pad` repo, err, add to `ExthCrypto.Math`
    total_size = size_in_bytes + ExthCrypto.Math.mod(32 - size_in_bytes, 32)

    ExthCrypto.Math.pad(bin, total_size)
  end

  @spec maybe_encode_unsigned(binary() | integer()) :: binary()
  defp maybe_encode_unsigned(bin) when is_binary(bin), do: bin
  defp maybe_encode_unsigned(int) when is_integer(int), do: :binary.encode_unsigned(int)

end
