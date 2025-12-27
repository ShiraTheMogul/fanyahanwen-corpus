import pandas as pd

def apply_1224_ranking(df):
    """
    Apply 1224 ranking system to the frequency data.
    
    In 1224 ranking:
    - Items with the same frequency get the same rank
    - The next rank after ties is the next available sequential number
    - Example: [100, 100, 90, 80, 80] → ranks: [1, 1, 3, 4, 4]
    """
    df = df.copy()
    
    # Sort by frequency descending to ensure proper ranking
    df = df.sort_values('n', ascending=False).reset_index(drop=True)
    
    # Apply 1224 ranking
    ranks = []
    current_rank = 1
    
    for i in range(len(df)):
        if i == 0:
            # First item always gets rank 1
            ranks.append(current_rank)
        else:
            # Check if current frequency equals previous frequency
            if df.iloc[i]['n'] == df.iloc[i-1]['n']:
                # Same frequency, same rank
                ranks.append(current_rank)
            else:
                # Different frequency, new rank equals current position + 1
                current_rank = i + 1
                ranks.append(current_rank)
    
    df['rank_1224'] = ranks
    return df

# Read the CSV file with UTF-8 encoding
try:
    df = pd.read_csv('LC_frequency_list.csv', encoding='utf-8')
except UnicodeDecodeError:
    try:
        df = pd.read_csv('LC_frequency_list.csv', encoding='utf-8-sig')
    except UnicodeDecodeError:
        df = pd.read_csv('LC_frequency_list.csv', encoding='gbk')  # Fallback for Chinese encodings

print(f"Successfully loaded {len(df)} Chinese characters")

# Apply 1224 ranking
ranked_df = apply_1224_ranking(df)

# Display the top 30 characters with their 1224 ranks
print("Top 30 characters with 1224 ranking:")
print("Rank\tCharacter\tFrequency")
print("-" * 40)

for _, row in ranked_df.head(30).iterrows():
    print(f"{row['rank_1224']}\t{row['chars']}\t\t{row['n']}")

# Show some examples of tied rankings
print("\n\nExamples of tied rankings:")
print("Rank\tCharacter\tFrequency")
print("-" * 40)

# Find some tied ranks to demonstrate
tied_examples = []
current_rank = None
count = 0

for _, row in ranked_df.iterrows():
    if count >= 10:  # Show 10 examples
        break
        
    if row['rank_1224'] != current_rank:
        current_rank = row['rank_1224']
        # Check if this rank has multiple entries
        same_rank = ranked_df[ranked_df['rank_1224'] == current_rank]
        if len(same_rank) > 1:
            for _, tied_row in same_rank.iterrows():
                tied_examples.append((tied_row['rank_1224'], tied_row['chars'], tied_row['n']))
                count += 1
                if count >= 10:
                    break

for rank, char, freq in tied_examples[:10]:
    print(f"{rank}\t{char}\t\t{freq}")

# Save the ranked data to a new CSV file with UTF-8 encoding
output_filename = 'LC_frequency_list_1224_ranked.csv'
ranked_df.to_csv(output_filename, index=False, encoding='utf-8-sig')
print(f"\nFull ranked data saved to '{output_filename}' with UTF-8 encoding")
print(f"Total characters processed: {len(ranked_df)}")

# Show some statistics
print(f"\nRanking statistics:")
print(f"Highest frequency: {ranked_df['n'].max():,} (rank 1)")
print(f"Lowest frequency: {ranked_df['n'].min():,}")
print(f"Number of unique ranks: {ranked_df['rank_1224'].nunique()}")
print(f"Average frequency: {ranked_df['n'].mean():,.0f}")

# Show distribution of top ranks
print(f"\nTop 10 rank distribution:")
top_10_ranks = ranked_df['rank_1224'].head(10).value_counts().sort_index()
for rank, count in top_10_ranks.items():
    chars = ranked_df[ranked_df['rank_1224'] == rank]['chars'].tolist()
    print(f"Rank {rank}: {count} character(s) - {', '.join(chars)}")
