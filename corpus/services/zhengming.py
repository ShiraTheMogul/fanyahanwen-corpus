import os
import glob

def rename_files(directory):
    """
    Mass renaming script for when i fuck something stupid up
    """
    for filepath in glob.glob(os.path.join(directory, "gujin_tushujicheng__juan_*")):
        if os.path.isfile(filepath):
            filename = os.path.basename(filepath)
            
            # Extract the juan number (everything after "juan_")
            if "_juan_" in filename:
                juan_part = filename.split("_juan_")[1]
                new_filename = f"欽定古今圖書集成_juan_{juan_part}"
                
                new_filepath = os.path.join(directory, new_filename)
                os.rename(filepath, new_filepath)
                print(f"Renamed: {filename} -> {new_filename}")

# Usage
rename_files("gujin_tushujicheng/")
