# Checks if a script has any non-Han characters and hits them with an orbital space laser manned by confucius himself
# Updated to CJK Extension J.

import os
import glob

def is_han_character(char):
    """
    Check if a character is a CJK Ideograph (Han character) based on Unicode ranges
    """
    code_point = ord(char)
    
    # CJK Unified Ideographs
    if 0x4E00 <= code_point <= 0x9FFF:
        return True
    # Extension A
    if 0x3400 <= code_point <= 0x4DBF:
        return True
    # Extension B
    if 0x20000 <= code_point <= 0x2A6DF:
        return True
    # Extension C
    if 0x2A700 <= code_point <= 0x2B73F:
        return True
    # Extension D
    if 0x2B740 <= code_point <= 0x2B81D:
        return True
    # Extension E
    if 0x2B820 <= code_point <= 0x2CEAD:
        return True
    # Extension F
    if 0x2CEB0 <= code_point <= 0x2EBE0:
        return True
    # Extension H
    if 0x31350 <= code_point <= 0x323AF:
        return True
    # Extension I
    if 0x2EBF0 <= code_point <= 0x2EE5D:
        return True
    # Extension J
    if 0x323B0 <= code_point <= 0x33479:
        return True
    # Supplement
    if 0x2F800 <= code_point <= 0x2FA1F:
        return True
    
    return False

def is_traditional_punctuation(char):
    """
    Check if character is traditional Chinese punctuation
    """
    code_point = ord(char)
    
    # Common Traditional Chinese punctuation ranges
    if 0x3000 <= code_point <= 0x303F:  # CJK Symbols and Punctuation
        return True
    if 0xFE10 <= code_point <= 0xFE1F:  # Vertical Forms
        return True
    if 0xFE30 <= code_point <= 0xFE4F:  # CJK Compatibility Forms
        return True
    if 0xFF00 <= code_point <= 0xFFEF:  # Halfwidth and Fullwidth Forms
        return True
    
    # Specific common punctuation marks
    traditional_punctuation = {
        '。', '，', '、', '；', '：', '？', '！', '「', '」', '『', '』', 
        '《', '》', '（', '）', '［', '］', '｛', '｝', '【', '】', '…', 
        '—', '～', '・', '〃', '〄', '々', '〆', '〇', '〈', '〉', '『',
        '』', '〖', '〗', '〘', '〙', '〚', '〛', '〜', '〝', '〞', '〟',
        '〰', '〱', '〲', '〳', '〴', '〵', '〶', '〷', '〸', '〹', '〺'
    }
    
    return char in traditional_punctuation

def is_allowed_character(char):
    """
    Check if character should be kept (Han characters or traditional punctuation)
    """
    return is_han_character(char) or is_traditional_punctuation(char) or char in '\n\r\t'

def filter_han_text(text):
    """
    Remove all non-Han characters and non-Chinese punctuation from text
    """
    result = []
    for char in text:
        if is_allowed_character(char):
            result.append(char)
    return ''.join(result)

def process_file(input_file, output_file=None):
    """
    Process a single file to remove non-Han characters and non-Chinese punctuation
    """
    if output_file is None:
        name, ext = os.path.splitext(input_file)
        output_file = f"{name}_han_only{ext}"
    
    try:
        with open(input_file, 'r', encoding='utf-8') as f:
            content = f.read()
        
        filtered_content = filter_han_text(content)
        
        with open(output_file, 'w', encoding='utf-8') as f:
            f.write(filtered_content)
        
        # Calculate statistics
        original_char_count = len(content)
        filtered_char_count = len(filtered_content)
        kept_chars = sum(1 for c in filtered_content if is_han_character(c))
        kept_punct = sum(1 for c in filtered_content if is_traditional_punctuation(c))
        removed_count = original_char_count - filtered_char_count
        
        print(f"✓ Processed: {input_file}")
        print(f"  Han characters kept: {kept_chars}")
        print(f"  Chinese punctuation kept: {kept_punct}")
        print(f"  Total characters kept: {filtered_char_count}")
        print(f"  Characters removed: {removed_count}")
        print(f"  Output: {output_file}")
        
    except Exception as e:
        print(f"✗ Error processing {input_file}: {e}")

def process_directory(directory, file_pattern="*.txt"):
    """
    Process all text files in a directory
    """
    search_pattern = os.path.join(directory, file_pattern)
    
    for filepath in glob.glob(search_pattern):
        if os.path.isfile(filepath):
            process_file(filepath)

def show_punctuation_samples():
    """
    Display samples of traditional Chinese punctuation for reference
    """
    samples = [
        "。句號", "，逗號", "、頓號", "；分號", "：冒號", 
        "？問號", "！驚嘆號", "「」引號", "『』雙引號", 
        "《》書名號", "（）括號", "【】方頭括號", 
        "…省略號", "—破折號", "～波浪號", "・間隔號"
    ]
    print("\nTraditional Chinese punctuation examples:")
    print("-" * 50)
    for sample in samples:
        print(f"  {sample}")
    print("-" * 50)

def interactive_process():
    """
    Interactive version that shows preview of changes
    """
    show_punctuation_samples()
    
    file_path = input("\nEnter the path to the text file (or directory): ").strip()
    
    if os.path.isdir(file_path):
        # Process directory
        pattern = input("Enter file pattern (e.g., *.txt, or press Enter for all .txt files): ").strip()
        if not pattern:
            pattern = "*.txt"
        process_directory(file_path, pattern)
    
    elif os.path.isfile(file_path):
        # Process single file
        if file_path.endswith(('.txt', '.md', '.text')):
            # Show preview
            with open(file_path, 'r', encoding='utf-8') as f:
                sample = f.read(500)  # First 500 chars for preview
            
            filtered_sample = filter_han_text(sample)
            
            print("\nPreview of changes:")
            print("Original (first 500 chars):")
            print("-" * 40)
            print(sample)
            print("-" * 40)
            print("\nFiltered (Han + Chinese punctuation only):")
            print("-" * 40)
            print(filtered_sample)
            print("-" * 40)
            
            # Show what will be kept/removed
            original_set = set(sample)
            filtered_set = set(filtered_sample)
            removed_chars = original_set - filtered_set
            
            print(f"\nCharacters that will be removed (sample):")
            removed_sample = list(removed_chars)[:20]  # Show first 20
            print(''.join(removed_sample) if removed_sample else "(none)")
            
            confirm = input("\nProcess this file? (y/n): ").lower().strip()
            if confirm == 'y':
                output_file = input("Enter output filename (or press Enter for auto-name): ").strip()
                if not output_file:
                    output_file = None
                process_file(file_path, output_file)
            else:
                print("Cancelled.")
        else:
            print("Please provide a text file (.txt, .md, .text)")
    else:
        print("File or directory not found!")

if __name__ == "__main__":
    print("正字：Han Character Rectification Tool")
    print("=" * 50)
    print("This tool removes all non-CJK Ideograph characters from text files.")
    print("Supports all CJK Unified Ideographs and Extensions A-J + Supplement")
    print()
    
    choice = input("Choose mode:\n1. Interactive (single file/directory)\n2. Process directory\nEnter choice (1 or 2): ").strip()
    
    if choice == "1":
        interactive_process()
    elif choice == "2":
        directory = input("Enter directory path: ").strip()
        pattern = input("Enter file pattern (e.g., *.txt, or press Enter for default): ").strip()
        if not pattern:
            pattern = "*.txt"
        process_directory(directory, pattern)
    else:
        print("Invalid choice")
