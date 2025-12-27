import pandas as pd

# Load frequency list
df = pd.read_csv("LC_frequency_list.csv")

# Sort by descending frequency
df_sorted = df.sort_values("n", ascending=False).reset_index(drop=True)

# Compute cumulative frequency and coverage
total = df_sorted["n"].sum()
df_sorted["cumulative"] = df_sorted["n"].cumsum()
df_sorted["coverage"] = df_sorted["cumulative"] / total

# Function to find threshold
def find_rank(threshold):
    row = df_sorted[df_sorted["coverage"] >= threshold].iloc[0]
    rank = int(row.name + 1)
    return {
        "rank": rank,
        "char": row["chars"],
        "coverage": float(row["coverage"])
    }

results = {
    "90%": find_rank(0.90),
    "95%": find_rank(0.95),
    "98%": find_rank(0.98),
    "99%": find_rank(0.99)
}

total_tokens = df['n'].sum()
print("Total Tokens:", total_tokens)
print("i+1 Thresholds:", results)
