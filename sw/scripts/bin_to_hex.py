import argparse

def convert_to_hex(input_file: str, output_file: str, word_size: int = 4, hex_format: str = "hex", big_endian: bool = False):
    with open(input_file, "rb") as f:
        data = f.read()

    words = [
        int.from_bytes(data[i:i+word_size], byteorder="big" if big_endian else "little")
        for i in range(0, len(data), word_size)
    ]
    
    hex_data = []
    match hex_format:
        case "hex":
            for w in words:
                hex_data.append(f"{w:0{word_size*2}x}")
        case "vmem":
            addr_width = len(f"{len(words)-1:x}")
            for i, w in enumerate(words):
                # hex_data.append(f"  assign memory[ {i} ] = {word_size*8}'h{w:0{word_size*2}x};")
                hex_data.append(f"assign memory[ 'h{i:0{addr_width}x} ] = {word_size*8}'h{w:0{word_size*2}x};")
            pass
        case _:
            raise ValueError(f"Unknown hex format: {hex_format}")

    with open(output_file, "w", newline="\n") as f:
        f.write("\n".join(hex_data) + "\n")

if __name__ == "__main__":
    parser = argparse.ArgumentParser()

    parser.add_argument("input_file", help="The .bin file to convert to hex")
    parser.add_argument("output_file", help="The output file to save the hex formatted data to")
    parser.add_argument("word_size", default=4, nargs="?", type=int, help="The number of bytes per word, defaults to 4")
    parser.add_argument("hex_format", default="hex", nargs="?", choices=["hex", "vmem"], help="The output format to use, defaults to hex")
    parser.add_argument("-B", "--big_endian", action="store_true", help="Use big endian ordering instead of little endian for reading the .bin file")

    args = parser.parse_args()

    if args.word_size < 1:
        raise ValueError(f"Invalid word size: {args.word_size}")

    convert_to_hex(args.input_file, args.output_file, args.word_size, args.hex_format, args.big_endian)
