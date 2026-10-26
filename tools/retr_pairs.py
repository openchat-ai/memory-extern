"""检索实验用的 (key, 改写, 实体) 三元组, 单独成模块避免 import 副作用."""
PAIRS = [
    ("The winner of the 1954 FIFA World Cup is", "Which team won the 1954 World Cup?", "1954"),
    ("The winner of the 1958 FIFA World Cup is", "Which team won the 1958 World Cup?", "1958"),
    ("The winner of the 1962 FIFA World Cup is", "Which team won the 1962 World Cup?", "1962"),
    ("The winner of the 1970 FIFA World Cup is", "Which team won the 1970 World Cup?", "1970"),
    ("The capital of France is", "What city is the capital of France?", "France"),
    ("The capital of Japan is", "What city is the capital of Japan?", "Japan"),
    ("The capital of Egypt is", "What city is the capital of Egypt?", "Egypt"),
    ("The capital of Peru is", "What city is the capital of Peru?", "Peru"),
    ("The currency of Japan is", "What money is used in Japan?", "Japan"),
    ("The currency of France is", "What money is used in France?", "France"),
    ("The language of Brazil is", "What tongue do people speak in Brazil?", "Brazil"),
    ("The language of Egypt is", "What tongue do people speak in Egypt?", "Egypt"),
]
