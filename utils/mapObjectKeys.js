/**
 * Map keys from object to object
 * 
 * @param {object} objFrom 
 * @param {object} objTo 
 * @returns 
 */
export const mapObjectKeys = (objFrom, objTo) => {
    const x = new objTo()
    for(const k in objFrom) {
        x[k] = objFrom[k]
    }
    return x
}