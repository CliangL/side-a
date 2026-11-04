import argparse
import os

from database import Database


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('action', choices=['migrate'])
    args = parser.parse_args()
    Database(os.environ['AI_HUB_DATABASE_URL']).migrate()
    print('AI Hub database ready')


if __name__ == '__main__':
    main()
