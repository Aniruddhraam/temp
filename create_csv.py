import csv
import random

output_file = "reviews_dataset.csv"
num_rows = 100

# Sample templates to generate realistic pairs
positive_reviews = [
    "Excellent product, highly recommended!",
    "Amazing quality and super fast shipping.",
    "Exactly what I needed. Five stars!",
    "Great customer service and fantastic value.",
    "Exceeded my expectations, will buy again.",
]

negative_reviews = [
    "Terrible quality, arrived broken.",
    "Waste of money. Do not buy this.",
    "Very disappointed with the performance.",
    "Customer service was unhelpful and rude.",
    "Item does not look like the pictures at all.",
]

# Open and write to the CSV file
with open(output_file, mode="w", newline="", encoding="utf-8") as file:
    writer = csv.writer(file)

    # 1. Write headers
    writer.writerow(["Review", "Label"])

    # 2. Generate rows
    for _ in range(num_rows):
        # Randomly choose sentiment label first
        label = random.choice(["Positive", "Negative"])

        # Select matching review text
        if label == "Positive":
            review = random.choice(positive_reviews)
        else:
            review = random.choice(negative_reviews)

        writer.writerow([review, label])

print(f"Saved {num_rows} review-label pairs to {output_file}")
