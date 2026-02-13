export const matcher = {
  firstMatch(regex, text) {
    try {
      const re = new RegExp(regex);
      const match = text.match(re);
      return match ? match[0] : "";
    } catch {
      return "";
    }
  },
};
