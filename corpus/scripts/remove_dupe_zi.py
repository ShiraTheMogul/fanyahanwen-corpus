# shamelessly stolen from https://www.geeksforgeeks.org/dsa/remove-duplicates-from-a-given-string/
def remove_duplicate(s):
    # Used as index in the modified string
    result = []
    seen = set()

    # Traverse through all characters
    for char in s:
        # Check if s[i] is present before it  
        if char not in seen:
            result.append(char)
            seen.add(char)
    
    # Join list to form the result string
    return ''.join(result)

# Driver code
s = "治官之屬：大宰，卿一人。小宰，中大夫二人。宰夫，下大夫四人；上士八人，中士十有六人，旅下士三十有二人；府六人，史十有二人，胥十有二人，徒百有二十人。又天官冢宰周禮零一二三四五六七八九十百千萬億〇弌弍弎亖唸壹貳叄䦉伍陸柒捌玖拾佰仟"
print(remove_duplicate(s))
