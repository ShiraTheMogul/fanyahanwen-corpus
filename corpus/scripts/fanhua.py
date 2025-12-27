import opencc
import sys
import os

def convert_file_to_traditional_chinese(input_file, output_file=None):
    """
    Converts all text in a file to Traditional Chinese
    
    Args:
        input_file (str): Path to input file
        output_file (str): Path to output file (optional)
    """
    try:
        # Initialize converter
        converter = opencc.OpenCC('s2t.json')  # Simplified to Traditional
        
        # Read input file
        with open(input_file, 'r', encoding='utf-8') as f:
            content = f.read()
        
        # Convert text
        converted_content = converter.convert(content)
        
        # Determine output filename
        if output_file is None:
            filename, ext = os.path.splitext(input_file)
            output_file = f"{filename}_traditional{ext}"
        
        # Write output file
        with open(output_file, 'w', encoding='utf-8') as f:
            f.write(converted_content)
        
        print(f"Conversion successful! Output file: {output_file}")
        
    except FileNotFoundError:
        print(f"Error: File '{input_file}' not found.")
    except Exception as e:
        print(f"An error occurred: {str(e)}")

if __name__ == "__main__":
    if len(sys.argv) < 2:
        print("Usage: python convert_chinese.py <input_file> [output_file]")
        print("Example: python convert_chinese.py input.txt output.txt")
        sys.exit(1)
    
    input_file = sys.argv[1]
    output_file = sys.argv[2] if len(sys.argv) > 2 else None
    
    convert_file_to_traditional_chinese(input_file, output_file)
